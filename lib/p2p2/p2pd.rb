require 'p2p2/head'
require 'p2p2/version'
require 'socket'

##
# P2p2::P2pd - 内网里的任意应用，访问另一个内网里的应用服务端。配对服务器端。
#
# 1.
#
# ```
#                    p2pd
#                    ^  ^
#                  ^    ^
#      “周立波的房间”     “周立波的房间”
#      ^                         ^
#     ^                         ^
#   p1 --> nat --><-- nat <-- p2
#
# ```
#
# 2.
#
# ```
#   ssh --> p2 --> (encode) --> p1 --> (decode) --> sshd
# ```
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
      @roles = {} # sock => :roomd / :room
      @infos = {}
      @rooms = {} # object_id => room
      @p1s = {} # title => room
      @p2s = {} # title => room

      ctlr, ctlw = IO.pipe
      @ctlw = ctlw
      @roles[ ctlr ] = :ctlr
      @reads << ctlr

      roomd = Socket.new( Socket::AF_INET, Socket::SOCK_STREAM, 0 )
      roomd.setsockopt( Socket::SOL_SOCKET, Socket::SO_REUSEADDR, 1 )
      roomd.bind( Socket.pack_sockaddr_in( @roomd_port, '0.0.0.0' ) )
      roomd.listen( 511 )

      @roles[ roomd ] = :roomd
      @reads << roomd
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
          sleep 3600

          if @infos.any?
            @mutex.synchronize do
              now = Time.new

              @infos.select{ | _, info | now - info[ :updated_at ] > 86400 }.each do | room, _ |
                @ctlw.write( [ CTL_CLOSE_ROOM, [ room.object_id ].pack( 'N' ) ].join )
              end
            end
          end
        end
      end
    end

    def read_ctlr( ctlr )
      case ctlr.read( 1 )
      when CTL_CLOSE_ROOM
        room_id = ctlr.read( 4 ).unpack( 'N' ).first
        room = @rooms[ room_id ]

        if room
          add_closing( room )
        end
      end
    end

    def read_roomd( roomd )
      begin
        room, addrinfo = roomd.accept_nonblock
      rescue IO::WaitReadable, Errno::EINTR
        return
      end

      @rooms[ room.object_id ] = room
      @roles[ room ] = :room
      @infos[ room ] = {
        title: nil,
        wbuff: '',
        sockaddr: addrinfo.to_sockaddr,
        updated_at: Time.new
      }
      @reads << room
    end

    def read_room( room )
      begin
        data = room.read_nonblock( PACK_SIZE )
      rescue IO::WaitReadable, Errno::EINTR, IO::WaitWritable
        return
      rescue Exception => e
        add_closing( room )
        return
      end

      info = @infos[ room ]
      info[ :updated_at ] = Time.new
      ctl_num = data[ 0 ].unpack( 'C' ).first

      case ctl_num
      when SET_TITLE
        title = data[ 1..-1 ]

        if title.size > 255
          puts 'title too long'
          add_closing( room )
          return
        end

        if @p1s.include?( title )
          puts "p1 #{ title.inspect } already exist #{ Time.new }"
          add_closing( room )
          return
        end

        if @p2s.include?( title )
          p2 = @p2s[ title ]
          p2_info = @infos[ p2 ]
          add_write( room, p2_info[ :sockaddr ] )
          add_write( p2, info[ :sockaddr ] )
          return
        end

        begin
          File.open( File.join( @roomd_dir, title ), 'w' )
        rescue Errno::ENOENT, ArgumentError => e
          puts "open title path #{ e.class }"
          add_closing( room )
          return
        end

        info[ :title ] = title
        @p1s[ title ] = room
      when PAIRING
        title = data[ 1..-1 ]

        if title.size > 255
          puts 'pairing title too long'
          add_closing( room )
          return
        end

        if @p2s.include?( title )
          puts "p2 #{ title.inspect } already exist #{ Time.new }"
          add_closing( room )
          return
        end

        if @p1s.include?( title )
          p1 = @p1s[ title ]
          p1_info = @infos[ p1 ]
          add_write( room, p1_info[ :sockaddr ] )
          add_write( p1, info[ :sockaddr ] )
          return
        end

        info[ :title ] = title
        @p2s[ title ] = room
      end
    end

    def write_room( room )
      if @closings.include?( room )
        close_room( room )
        return
      end

      info = @infos[ room ]
      room.write( info[ :wbuff ] )
      @writes.delete( room )
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
        info[ :wbuff ] = data
      end

      unless @writes.include?( sock )
        @writes << sock
      end
    end

    def close_room( room )
      room.close
      @rooms.delete( room.object_id )
      @reads.delete( room )
      @writes.delete( room )
      @closings.delete( room )
      @roles.delete( room )
      info = @infos.delete( room )

      if info && info[ :title ]
        title_path = File.join( @roomd_dir, info[ :title ] )

        if File.exist?( title_path )
          File.delete( title_path )
          @p1s.delete( info[ :title ] )
        else
          @p2s.delete( info[ :title ] )
        end
      end
    end
  end
end
