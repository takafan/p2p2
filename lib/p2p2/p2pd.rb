require 'nio'
require 'socket'

##
# P2p2::P2pd
#
# 包结构
#
# N: 1+ pcur    -> traffic between p1 and p2
#    0  ctl msg -> C: 1 p1 to roomd: heartbeat
#                     2 p2 to roomd: p1 address
#                     3 p2 to p1: heartbeat
#                     4 roomd to p1: p2 address
#                     5 p1 to p2: heartbeat
#                     6 p2 to p1: fin
#                     7 p1 to p2: fin
#
# infos，存取sock信息，根据角色，sock => {}：
#
# {
#   role: :roomd,
#   mon: mon,
#   ip_port: '6.6.6.6:12345',
#   tmp_path: '/tmp/p2pd/6.6.6.6:12345'
# }
#
module P2p2
  class P2pd
    RESEND_LIMIT = 20 # 重传次数上限

    def initialize( roomd_port = 6060, tmp_dir = '/tmp/p2pd' )
      # @writes = {} # sock => ''
      selector = NIO::Selector.new

      roomd = Socket.new( Socket::AF_INET, Socket::SOCK_DGRAM, 0 )
      roomd.setsockopt( Socket::SOL_SOCKET, Socket::SO_REUSEPORT, 1 )
      roomd.bind( Socket.pack_sockaddr_in( roomd_port, '0.0.0.0' ) )

      @tmp_dir = tmp_dir
      # @timeout = 3600
      @mutex = Mutex.new
      @selector = selector
      @infos = {
        roomd => {
          role: :roomd,
          mon: selector.register( roomd, :r ),
          p1s: {} # [ ip, port ] => [ tmp_path, now ]
        }
      }
    end

    def looping
      loop do
        @selector.select do | mon |
          sock = mon.io

          if sock.closed?
            puts 'sock already closed'
            next
          end

          info = @infos[ sock ]

          if mon.readable?
            case info[ :role ]
            when :roomd
              # begin
              #   room, addr = sock.accept_nonblock
              # rescue IO::WaitReadable, Errno::EINTR
              #   next
              # end
              data, addrinfo, rflags, *controls = sock.recvmsg

              # room.setsockopt( Socket::SOL_TCP, Socket::TCP_NODELAY, 1 )
              # @writes[ room ] = ''

              ctl_num = data[ 0 ].unpack( 'C' ).first

              if ctl_num == 1
                # 1 p1 to roomd: heartbeat
                now = Time.new
                ip_port = addrinfo.ip_unpack
                client = info[ :p1s ][ ip_port ]

                if info[ :p1s ].include?( ip_port )
                  info[ :p1s ][ ip_port ][ 1 ] = Time.new
                else
                  filename = [ ip_port.join( ':' ), data ].join( '-' )
                  tmp_path = File.join( @tmp_dir, filename )

                  begin
                    File.open( tmp_path, 'w' )
                  rescue Errno::ENOENT, ArgumentError => e
                    puts "save p1 tmp file #{ ip_port.inspect } #{ e.class }"
                    next
                  end

                  info[ :p1s ][ ip_port ] = [ tmp_path, now ]
                end
              elsif ctl_num == 2
                # p2 to roomd: p1 address
              end


            when :room

              if data[ 0, 4 ] == 'come' # connect me!
                p2_info = @infos[ mon ]

                ip_port = data[ 4..-1 ]
                p1_room_mon, p1_info = @infos.find{ |_, info| info[ :ip_port ] == ip_port }

                unless p1_info
                  sock.setsockopt( Socket::SOL_SOCKET, Socket::SO_LINGER, [ 1, 0 ].pack( 'ii' ) )
                  close_mon( mon )
                  next
                end

                @writes[ p1_room_mon.io ] << p2_info[ :ip_port ]
                p1_room_mon.add_interest( :w )

                begin
                  File.delete( p1_info[ :tmp_path ] )
                rescue Errno::ENOENT
                end

                begin
                  File.delete( p2_info[ :tmp_path ] )
                rescue Errno::ENOENT
                end

                @infos.delete( p1_room_mon )
                @infos.delete( mon )
              else
                puts 'ghost?'
              end
            end
          end

          if mon.writable?
            if sock.closed?
              next
            end

            data = @writes[ sock ]

            begin
              written = sock.write_nonblock( data )
            rescue IO::WaitWritable, Errno::EINTR, IO::WaitReadable
              next
            rescue Exception => e
              close_mon( mon )
              next
            end

            @timestamps[ mon ] = Time.new
            @writes[ sock ] = data[ written..-1 ]

            unless @writes[ sock ].empty?
              next
            end

            mon.remove_interest( :w )
          end
        end
      end
    end

    def quit!
      @roles.each{ | mon, _ | mon.io.close }
      @infos.each do | _, info |
        begin
          File.delete( info[ :tmp_path ] )
        rescue Errno::ENOENT
        end
      end

      exit
    end

    private

    def close_mon( mon )
      sock = mon.io
      sock.close

      @writes.delete( sock )
      @selector.deregister( sock )
      @roles.delete( mon )
      info = @infos.delete( mon )

      if info
        begin
          File.delete( info[ :tmp_path ] )
        rescue Errno::ENOENT
        end
      end

      @timestamps.delete( mon )
    end

  end
end
