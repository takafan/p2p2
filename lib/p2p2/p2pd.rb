require 'nio'
require 'socket'

##
# P2p2::P2pd
#
#```
#                p2pd                           p2pd
#                ^                              ^
#               ^                              ^
#    sshd <- p2p1                            p2p2 <- ssh
#               \                            ,
#                `swap -> nat <-> nat <- swap
#```
#
# 包结构
#
# N: 1+ pcur    -> traffic between p1 and p2
#    0  ctl msg -> C: 1. p1 to roomd: i'm alive -> custom head
#                     2. p2 to roomd: tell p1, hole me -> p1 sockaddr
#                     3. p2 to p1: i'm alive
#                     4. roomd to p1: p2's hole -> p2 sockaddr
#                     5. p1 to p2: i'm alive
#                     6. roomd to p1: i'm fin
#                     7. p1 to roomd: i'm fin
#                     8. p1 to p2: i'm fin
#                     9. p2 to p1: i'm fin
#
# infos，存取sock信息，根据角色，sock => {}：
#
# {
#   role: :roomd,
#   mon: mon,
#   p1s: {
#     sockaddr => {
#       filename: '6.6.6.6:12345-周立波的房间',
#       timestamp: now
#     }
#   }
# }
#
module P2p2
  class P2pd
    def initialize( roomd_port = 6060, tmp_dir = '/tmp/p2pd' )
      selector = NIO::Selector.new

      roomd = Socket.new( Socket::AF_INET, Socket::SOCK_DGRAM, 0 )
      roomd.setsockopt( Socket::SOL_SOCKET, Socket::SO_REUSEPORT, 1 )
      roomd.bind( Socket.pack_sockaddr_in( roomd_port, '0.0.0.0' ) )

      roomd_info = {
        mon: selector.register( roomd, :r ),
        p1s: {}
      }

      @tmp_dir = tmp_dir
      @mutex = Mutex.new
      @selector = selector
      @roomd = roomd
      @roomd_info = roomd_info

      @infos = {
        roomd => roomd_info
      }
    end

    def looping
      # 删除过期的p1
      loop_expire

      loop do
        @selector.select do | mon |
          sock = mon.io
          info = @infos[ sock ]

          if mon.readable?
            data, addrinfo, rflags, *controls = sock.recvmsg
            pcur, ctl_num = data[ 0, 5 ].unpack( 'NC' )

            if pcur != 0
              next
            end

            if ctl_num == 1
              # 1. p1 to roomd: i'm alive -> custom head
              now = Time.new
              p1_addr = addrinfo.to_sockaddr

              if info[ :p1s ].include?( p1_addr )
                info[ :p1s ][ p1_addr ][ :timestamp ] = Time.new
              else
                filename = save_tmpfile( data[ 5..-1 ], addrinfo, @tmp_dir )

                unless filename
                  next
                end

                info[ :p1s ][ p1_addr ] = {
                  filename: filename,
                  timestamp: now
                }
              end
            elsif ctl_num == 2
              # 2. p2 to roomd: tell p1, hole me -> p1 sockaddr
              p1_addr = data[ 5, 16 ]

              unless @room_info[ :p1s ].include?( p1_addr )
                puts 'p1 not found'
                next
              end

              # send: 4. roomd to p1: p2's hole -> p2 sockaddr
              @roomd.sendmsg( [ [ 0, 4 ].pack( 'NC' ), addrinfo.to_sockaddr ].join, 0, p1_addr )
            elsif ctl_num == 7
              # 7. p1 to roomd: i'm fin
              sockaddr = addrinfo.to_sockaddr
              p1_info = @roomd_info[ :p1s ][ sockaddr ]

              unless p1_info
                puts 'p1 not found'
                next
              end

              del_p1( sockaddr, p1_info )
            end
          end
        end
      end
    end

    def quit!
      @mutex.synchronize do
        @roomd_info[ :p1s ].each do | p1_sockaddr, p1_info |
          del_tmpfile( p1_info[ :filename ] )
        end
      end

      exit
    end

    private

    def loop_expire
      Thread.new do
        loop do
          now = Time.new

          @mutex.synchronize do
            @roomd_info[ :p1s ].select{ | _, p1_info | now - p1_info[ :timestamp ] > 7200 }.each do | p1_sockaddr, p1_info |
              del_p1( p1_sockaddr, p1_info )
            end
          end

          sleep 3600
        end
      end
    end

    def save_tmpfile( data, addrinfo, tmp_dir )
      filename = addrinfo.ip_unpack.join( ':' )

      unless data.empty?
        filename = [ filename, data ].join( '-' )
      end

      path = File.join( tmp_dir, filename )

      begin
        File.open( path, 'w' )
      rescue Errno::ENOENT, ArgumentError => e
        puts "save p1 tmpfile #{ path.inspect } #{ e.class }"
        filename = nil
      end

      filename
    end

    def del_p1( p1_sockaddr, p1_info )
      del_tmpfile( p1_info[ :filename ] )
      @roomd_info[ :p1s ].delete( p1_sockaddr )
    end

    def del_tmpfile( filename )
      begin
        File.delete( File.join( @tmp_dir, filename ) )
      rescue Errno::ENOENT
      end
    end
  end
end
