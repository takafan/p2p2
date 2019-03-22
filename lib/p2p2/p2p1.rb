require 'nio'
require 'socket'

##
# {
#   role: :p1,
#   mon: mon,
#   roomd_addr: Socket.sockaddr_in( roomd_port, roomd_host ),
#   appd_addr: Socket.sockaddr_in( appd_port, appd_host ),
#   custom_head: custom_head,
#   p2s: {
#     p2_sockaddr => {
#       timestamp: now,
#       app: app,
#       memories: {
#         pack_id => [ '', now, 0 ]
#       }
#     }
#   }
# }
#
module P2p2
  class P2p1

    def initialize( roomd_host, roomd_port, appd_host, appd_port, custom_head = nil )
      selector = NIO::Selector.new
      p1 = Socket.new( Socket::AF_INET, Socket::SOCK_DGRAM, 0 )
      p1.bind( Socket.sockaddr_in( 0, '0.0.0.0' ) )

      p1_info = {
        role: :p1,
        mon: selector.register( p1, :r ),
        roomd_addr: Socket.sockaddr_in( roomd_port, roomd_host ),
        appd_addr: Socket.sockaddr_in( appd_port, appd_host ),
        custom_head: custom_head,
        p2s: {}
      }

      @appd_addr = Socket.sockaddr_in( appd_port, appd_host )
      @selector = selector
      @p1 = p1
      @p1_info = p1_info
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
            when :p1
              data, addrinfo, rflags, *controls = sock.recvmsg
              p2_pcur = data[ 0, 4 ].unpack( 'N' ).first

              if p2_pcur == 0
                ctl_num = data[ 5 ].unpack( 'C' ).first

                if ctl_num == 3
                  # 3. p2 to p1: i'm alive
                  p2_sockaddr = addrinfo.to_sockaddr
                  p2_info = info[ :p2s ][ p2_sockaddr ]
                  p2_info[ :timestamp ] = Time.new
                elsif ctl_num == 4
                  # 4. roomd to p1: p2's hole -> p2 sockaddr
                  p2_addr = data[ 5, 16 ]

                  if info[ :p2s ].include?( p2_addr )
                    next
                  end

                  app = Socket.new( Socket::AF_INET, Socket::SOCK_STREAM, 0 )
                  app.setsockopt( Socket::SOL_TCP, Socket::TCP_NODELAY, 1 )

                  begin
                    app.connect_nonblock( @appd_addr )
                  rescue IO::WaitWritable, Errno::EINTR
                  rescue Exception => e
                    puts "connect to appd #{ e.class }"
                    app.close
                    next
                  end

                  @infos[ app ] = {
                    role: :app,
                    mon: @selector.register( app, :r ),
                    pcur: 0,
                    p2_pcur: 0,
                    wbuff: '',
                    pieces: {},
                    p2_addr: p2_addr
                  }

                  info[ :p2s ][ p2_addr ] = {
                    timestamp: Time.new,
                    memories: {},
                    app: app
                  }
                elsif ctl_num == 8
                  # 8. p2 to p1: i'm fin
                  info[ :p2s ].delete( addrinfo )
                end

                next
              end

              p2_sockaddr = addrinfo.to_sockaddr
              p2_info = info[ :p2s ][ p2_sockaddr ]

              unless p2_info
                next
              end

              app = p2_info[ :app ]

              if app.closed?
                puts 'app already closed'
                next
              end

              app_info = @infos[ app ]

              if p2_pcur <= app_info[ :p2_pcur ]
                next
              end

              data = data[ 8..-1 ]

              # 解混淆
              if source_pcur == 1
                data = swap( data )
              end

              # 放进dest的写前缓存，跳号放碎片缓存
              if source_pcur - dest_info[ :source_pcur ] == 1
                while dest_info[ :pieces ].include?( source_pcur + 1 )
                  data << dest_info[ :pieces ].delete( source_pcur + 1 )
                  source_pcur += 1
                end

                add_buff2( dest_info, data )
                dest_info[ :source_pcur ] = source_pcur
              else
                dest_info[ :pieces ][ source_pcur ] = data
              end

              info[ :wbuff ] << data
              info[ :mon ].add_interest( :w )
            when :app
              if sock.closed?
                next
              end

              twin = @twins[ mon ]

              if twin.io.closed?
                connect_roomd
                break
              end

              begin
                data = sock.read_nonblock( 4096 )
              rescue IO::WaitReadable, Errno::EINTR, IO::WaitWritable => e
                next
              rescue Exception => e
                puts "read #{ @roles[ mon ] } #{ e.class }"
                connect_roomd
                break
              end

              @timestamps[ mon ] = Time.new

              if @swaps2.delete( twin )
                data = "#{ [ data.size ].pack( 'n' ) }#{ swap( data ) }"
              end

              buffer( twin, data )
            end
          end

          if mon.writable?
            if sock.closed?
              next
            end

            data = @writes[ sock ]

            begin
              written = sock.write_nonblock( data )
            rescue IO::WaitWritable, Errno::EINTR, IO::WaitReadable => e
              next
            rescue Exception => e
              puts "write #{ @roles[ mon ] } #{ e.class }"
              connect_roomd
              break
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
    rescue Interrupt => e
      puts e.class
      quit!
    end

    def quit!
      @mutex.synchronize do
        @p1_info[ :p2s ].each do | p2_sockaddr, p2_info |
          # send: 8 p1 to p2: i'm fin
          @p1.sendmsg( pack_ctlmsg( 8 ), 0, p2_sockaddr )
          del_tmpfile( p1_info[ 0 ] )
        end
      end

      exit
    end

    private

    def loop_heartbeat
      Thread.new do
        loop do
          send_heartbeat_to_roomd

          # send: 5 p1 to p2: i'm alive
          @p1_info[ :p2s ].each do | p2_sockaddr, _ |
            @p1.sendmsg( pack_ctlmsg( 5 ), 0, p2_sockaddr )
          end

          sleep 59
        end
      end
    end

    def send_heartbeat_to_roomd
      # 1. p1 to roomd: i'm alive -> custom head
      ctlmsg = pack_ctlmsg( 1, @p1_info[ :custom_head ] )
      @p1.sendmsg( ctlmsg, 0, @p1_info[ :roomd_addr ] )
    end

    def pack_ctlmsg( ctl_num, data = nil )
      ctlmsg = [ 0, ctl_num ].pack( 'NC' )

      if data
        ctlmsg = [ ctlmsg, data ].join
      end

      ctlmsg
    end

    def add_buff( info, data )
      info[ :wbuff ] << data
      info[ :mon ].add_interest( :w )
    end

    def swap( data )
      data
    end

  end
end
