require 'p2p2/head'
require 'p2p2/version'
require 'socket'

##
# P2p2::P2pd - 处于nat里的任意应用，访问处于另一个nat里的应用服务端，借助一根p2p管道。配对服务器端。
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
      @reads = []
      @writes = []
      @closings = []
      @socks = {} # object_id => sock
      @pending_p1s = {} # title => room
      @pending_p2s = {} # title => room
      @roles = {} # sock => :roomd / :room
      @infos = {}

      ctlr, ctlw = IO.pipe
      @ctlw = ctlw
      @roles[ ctlr ] = :ctlr
      @reads << ctlr

      new_roomd
    end

    def looping
      puts 'looping'

      loop_expire

      loop do
        rs, ws = IO.select( @reads, @writes )

        @mutex.synchronize do
          rs.each do | sock |
            case @roles[ sock ]
            when :ctlr
              read_ctlr( sock )
            when :roomd
              read_roomd( sock )
            when :room
              read_room( sock )
            end
          end

          ws.each do | sock |
            case @roles[ sock ]
            when :room
              write_room( sock )
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

              @infos.select{ | _, info | now - info[ :updated_at ] > 1800 }.each do | room, _ |
                @ctlw.write( [ CTL_CLOSE_ROOM, [ room.object_id ].pack( 'N' ) ].join )
              end
            end
          end
        end
      end
    end

    def read_ctlr( sock )
      case sock.read( 1 )
      when CTL_CLOSE_ROOM
        room_id = sock.read( 4 ).unpack( 'N' ).first
        room = @socks[ room_id ]

        if room
          add_closing( room )
        end
      end
    end

    def read_roomd( sock )
      begin
        room, addr = sock.accept_nonblock
      rescue IO::WaitReadable, Errno::EINTR
        return
      end

      @socks[ room.object_id ] = room
      @roles[ room ] = :room
      @infos[ room ] = {
        title: nil,
        wbuff: '',
        updated_at: Time.new,
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
        add_closing( sock )
        return
      end

      info = @infos[ sock ]
      info[ :updated_at ] = Time.new

      until data.empty?
        ctl_num = data[ 0 ].unpack( 'C' ).first

        case ctl_num
        when HEARTBEAT
          data = data[ 1..-1 ]
        when SET_TITLE
          len = data[ 1, 2 ].unpack( 'n' ).first

          if len > 255
            puts "title too long"
            add_closing( sock )
            return
          end

          title = data[ 3, len ]

          if @pending_p2s.include?( title )
            p2 = @pending_p2s[ title ]
            p2_info = @infos[ p2 ]
            add_write( sock, p2_info[ :sockaddr ] )
            add_write( p2, info[ :sockaddr ] )
          else
            @pending_p1s[ title ] = sock
            info[ :title ] = title

            begin
              File.open( File.join( @roomd_dir, title ), 'w' )
            rescue Errno::ENOENT, ArgumentError => e
              puts "open title path #{ e.class }"
              add_closing( sock )
              return
            end
          end

          data = data[ ( 3 + len )..-1 ]
        when PAIRING
          len = data[ 1, 2 ].unpack( 'n' ).first

          if len > 255
            puts 'pairing title too long'
            add_closing( sock )
            return
          end

          title = data[ 3, len ]

          if @pending_p1s.include?( title )
            p1 = @pending_p1s[ title ]
            p1_info = @infos[ p1 ]
            add_write( sock, p1_info[ :sockaddr ] )
            add_write( p1, info[ :sockaddr ] )
          else
            @pending_p2s[ title ] = sock
            info[ :title ] = title
          end

          data = data[ ( 3 + len )..-1 ]
        end
      end
    end

    def write_room( sock )
      if @closings.include?( sock )
        close_sock( sock )
        return
      end

      info = @infos[ sock ]
      data = info[ :wbuff ]

      if data.empty?
        @writes.delete( sock )
        return
      end

      sock.write( data )
      info[ :wbuff ].clear
    end

    def add_closing( sock )
      unless @closings.include?( sock )
        @reads.delete( sock )
        @closings <<  sock
      end

      add_write( sock )
    end

    def add_write( sock, data = nil )
      if data
        info = @infos[ sock ]
        info[ :wbuff ] << data
      end

      unless @writes.include?( sock )
        @writes << sock
      end
    end

    def close_sock( sock )
      sock.close
      @reads.delete( sock )
      @writes.delete( sock )
      @closings.delete( sock )
      @socks.delete( sock.object_id )
      @roles.delete( sock )
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
