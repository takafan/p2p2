require 'p2p2/head'
require 'p2p2/version'
require 'socket'

##
# P2p2::P2pd - 处于各自nat里的两端p2p。匹配服务器端。
#
#```
#              p2pd                              p2pd
#             ^                                 ^
#            ^                                 ^
#  ssh --> p2 --> encode --> nat --> nat --> p1 --> decode --> sshd
#
#```
#
# usage
# =====
#
# 1. Girl::P2pd.new( 5050 ).looping # @server
#
# 2. Girl::P1.new( 'your.server.ip', 5050, '127.0.0.1', 22, '周立波' ).looping # @home1
#
# 3. Girl::P2.new( 'your.server.ip', 5050, '0.0.0.0', 2222, '周立波' ).looping # @home2
#
# 4. ssh -p2222 libo@localhost
#
module P2p2
  class P2pd

    ##
    # roomd_port    配对服务器端口
    # roomd_dir     可在该目录下看到所有的p1
    def initialize( roomd_port = 5050, roomd_dir = '/tmp' )
      @roomd_port = roomd_port
      @roomd_dir = roomd_dir
      @mutex = Mutex.new
      @roles = {} # sock => :roomd / :room
      @pending_p1s = {} # title => room
      @pending_p2s = {} # title => room
      @infos = {}
      @reads = []

      new_roomd
    end

    def looping
      puts 'looping'

      loop_expire

      loop do
        rs, _ = IO.select( @reads )

        @mutex.synchronize do
          rs.each do | sock |
            case @roles[ sock ]
            when :roomd
              read_roomd( sock )
            when :room
              read_room( sock )
            end
          end
        end
      end
    rescue Interrupt => e
      puts e.class
      quit!
    end

    def quit!
      exit
    end

    private

    def loop_expire
      Thread.new do
        loop do
          sleep 900

          if @infos.any?
            @mutex.synchronize do
              now = Time.new

              @infos.select{ | _, info | info[ :last_coming_at ] && ( now - info[ :last_coming_at ] > 1800 ) }.each do | room, _ |
                close_sock( room )
              end
            end
          end
        end
      end
    end

    def read_roomd( sock )
      begin
        room, addr = sock.accept_nonblock
      rescue IO::WaitReadable, Errno::EINTR
        return
      end

      @roles[ room ] = :room
      @infos[ room ] = {
        title: nil,
        last_coming_at: nil,
        sockaddr: addr.to_sockaddr
      }
      @reads << room
    end

    def read_room( sock )
      begin
        data = sock.read_nonblock( PACK_SIZE )
      rescue IO::WaitReadable, Errno::EINTR, IO::WaitWritable
        return
      rescue Exception => e
        close_sock( sock )
        return
      end

      info = @infos[ sock ]
      info[ :last_coming_at ] = Time.new

      until data.empty?
        ctl_num = data[ 0 ].unpack( 'C' ).first

        case ctl_num
        when HEARTBEAT
          data = data[ 1..-1 ]
        when SET_TITLE
          len = data[ 1, 2 ].unpack( 'n' ).first

          if len > 255
            puts "title too long"
            close_sock( sock )
            return
          end

          title = data[ 3, len ]

          if @pending_p2s.include?( title )
            p2 = @pending_p2s[ title ]
            p2_info = @infos[ p2 ]
            sock.write( p2_info[ :sockaddr ] )
            p2.write( info[ :sockaddr ] )
          elsif @pending_p1s.include?( title )
            puts "pending p1 #{ title.inspect } already exist"
            close_sock( sock )
            return
          else
            @pending_p1s[ title ] = sock
            info[ :title ] = title

            begin
              File.open( File.join( @roomd_dir, title ), 'w' )
            rescue Errno::ENOENT, ArgumentError => e
              puts "open title path #{ e.class }"
              close_sock( sock )
              return
            end
          end

          data = data[ ( 3 + len )..-1 ]
        when PAIRING
          len = data[ 1, 2 ].unpack( 'n' ).first

          if len > 255
            puts 'pairing title too long'
            close_sock( sock )
            return
          end

          title = data[ 3, len ]

          if @pending_p1s.include?( title )
            p1 = @pending_p1s[ title ]
            p1_info = @infos[ p1 ]
            sock.write( p1_info[ :sockaddr ] )
            p1.write( info[ :sockaddr ] )
          elsif @pending_p2s.include?( title )
            puts "pending p2 #{ title.inspect } already exist"
            close_sock( sock )
            return
          else
            @pending_p2s[ title ] = sock
            info[ :title ] = title
          end

          data = data[ ( 3 + len )..-1 ]
        end
      end
    end

    def close_sock( sock )
      sock.close
      @roles.delete( sock )
      @reads.delete( sock )
      info = @infos.delete( sock )

      if info && info[ :title ]
        @pending_p1s.delete( info[ :title ] )
        @pending_p2s.delete( info[ :title ] )

        begin
          File.delete( File.join( @roomd_dir, info[ :title ] ) )
        rescue Errno::ENOENT
        end
      end

      info
    end

    def new_roomd
      roomd = Socket.new( Socket::AF_INET, Socket::SOCK_STREAM, 0 )
      roomd.setsockopt( Socket::SOL_SOCKET, Socket::SO_REUSEADDR, 1 )
      roomd.bind( Socket.pack_sockaddr_in( @roomd_port, '0.0.0.0' ) )
      roomd.listen( 511 )

      @roles[ roomd ] = :roomd
      @reads << roomd
    end
  end
end
