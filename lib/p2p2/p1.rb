require 'p2p2/head'
require 'p2p2/hex'
require 'p2p2/version'
require 'socket'

##
# P2p2::P1 - 内网里的任意应用，访问另一个内网里的应用服务端。p1端。
#
module P2p2
  class P1

    ##
    # roomd_host    配对服务器ip
    # roomd_port    配对服务器端口
    # appd_host     任意的一个应用的ip
    # appd_port     应用端口
    # title         约定的房间名
    # app_chunk_dir 文件缓存目录，缓存app来不及写的流量
    # p1_chunk_dir  文件缓存目录，缓存p1来不及写的流量
    #
    def initialize( roomd_host, roomd_port, appd_host, appd_port, title, app_chunk_dir = '/tmp', p1_chunk_dir = '/tmp' )
      @roomd_sockaddr = Socket.sockaddr_in( roomd_port, roomd_host )
      @appd_sockaddr = Socket.sockaddr_in( appd_port, appd_host )
      @title = title
      @app_chunk_dir = app_chunk_dir
      @p1_chunk_dir = p1_chunk_dir
      @hex = P2p2::Hex.new
      @mutex = Mutex.new
      @reads = []
      @writes = []
      @closings = []
      @roles = {}  # sock => :ctlr / :room / :p1 / :app
      @infos = {}
      @reconn_room_times = 0

      ctlr, ctlw = IO.pipe
      @ctlw = ctlw
      @roles[ ctlr ] = :ctlr
      @reads << ctlr

      new_room
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
            when :room
              read_room( sock )
            when :p1
              read_p1( sock )
            when :app
              read_app( sock )
            end
          end

          ws.each do | sock |
            case @roles[ sock ]
            when :room
              write_room( sock )
            when :p1
              write_p1( sock )
            when :app
              write_app( sock )
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
          sleep 60

          if Time.new - @room_info[ :updated_at ] > 1800
            @mutex.synchronize do
              @ctlw.write( CTL_CLOSE_ROOM )
            end
          end
        end
      end
    end

    ##
    # read ctlr
    #
    def read_ctlr( ctlr )
      case ctlr.read( 1 )
      when CTL_CLOSE_ROOM
        unless @room.closed?
          add_closing( @room )
        end
      end
    end

    ##
    # read room
    #
    def read_room( room )
      begin
        data = room.read_nonblock( PACK_SIZE )
      rescue IO::WaitReadable, Errno::EINTR, IO::WaitWritable
        return
      rescue Errno::ECONNREFUSED, Errno::ECONNRESET => e
        puts "read room #{ e.class } #{ Time.new }"
        raise e if @reconn_room_times >= REROOM_LIMIT
        @reconn_room_times += 1
        sleep 5
        add_closing( room )
        return
      rescue EOFError => e
        puts "read room #{ e.class } #{ Time.new }"
        sleep 5
        add_closing( room )
        return
      end

      @reconn_room_times = 0
      info = @infos[ room ]
      info[ :p2_sockaddr ] = data
      info[ :updated_at ] = Time.new
      new_p1
    end

    ##
    # read p1
    #
    def read_p1( p1 )
      begin
        data = p1.read_nonblock( PACK_SIZE )
      rescue IO::WaitReadable, Errno::EINTR, IO::WaitWritable
        return
      rescue Errno::ECONNREFUSED => e
        if @room_info[ :renew_p1_times ] >= REP2P_LIMIT
          raise e
        end

        sleep 1
        add_closing( p1 )
        info = @infos[ p1 ]
        info[ :need_renew ] = true
        @room_info[ :renew_p1_times ] += 1
        return
      rescue Exception => e
        add_closing( p1 )
        return
      end

      info = @infos[ p1 ]

      if info[ :app ].nil? || info[ :app ].closed?
        add_closing( p1 )
        return
      end

      if info[ :need_decode ]
        len = data[ 0, 2 ].unpack( 'n' ).first
        head = @hex.decode( data[ 2, len ] )
        data = head + data[ ( 2 + len )..-1 ]
        info[ :need_decode ] = false
      end

      add_write( info[ :app ], data )
      @room_info[ :updated_at ] = Time.new
    end

    ##
    # read app
    #
    def read_app( app )
      begin
        data = app.read_nonblock( PACK_SIZE )
      rescue IO::WaitReadable, Errno::EINTR, IO::WaitWritable
        return
      rescue Exception => e
        add_closing( app )
        return
      end

      info = @infos[ app ]

      if info[ :p1 ].nil? || info[ :p1 ].closed?
        add_closing( app )
        return
      end

      if info[ :need_encode ]
        data = @hex.encode( data )
        data = [ [ data.size ].pack( 'n' ), data ].join
        info[ :need_encode ] = false
      end

      add_write( info[ :p1 ], data )
      @room_info[ :updated_at ] = Time.new
    end

    ##
    # write room
    #
    def write_room( room )
      if @closings.include?( room )
        close_sock( room )
        new_room
        return
      end

      info = @infos[ room ]
      room.write( info[ :wbuff ] )
      @writes.delete( room )
    end

    ##
    # write p1
    #
    def write_p1( p1 )
      if @closings.include?( p1 )
        info = close_sock( p1 )

        if info[ :need_renew ]
          new_p1
          return
        end

        unless info[ :app ].closed?
          add_closing( info[ :app ] )
        end

        unless @room.closed?
          add_closing( @room )
        end

        return
      end

      info = @infos[ p1 ]
      data, from = get_buff( info )

      if data.empty?
        @writes.delete( p1 )
        return
      end

      begin
        written = p1.write_nonblock( data )
      rescue IO::WaitWritable, Errno::EINTR, IO::WaitReadable
        return
      rescue Exception => e
        add_closing( p1 )
        return
      end

      data = data[ written..-1 ]
      info[ from ] = data
    end

    ##
    # write app
    #
    def write_app( app )
      if @closings.include?( app )
        info = close_sock( app )

        unless info[ :p1 ].closed?
          add_closing( info[ :p1 ] )
        end

        return
      end

      info = @infos[ app ]
      data, from = get_buff( info )

      if data.empty?
        @writes.delete( app )
        return
      end

      begin
        written = app.write_nonblock( data )
      rescue IO::WaitWritable, Errno::EINTR, IO::WaitReadable
        return
      rescue Exception => e
        add_closing( app )
        return
      end

      data = data[ written..-1 ]
      info[ from ] = data
    end

    def get_buff( info )
      data, from = info[ :cache ], :cache

      if data.empty?
        if info[ :chunks ].any?
          path = File.join( info[ :chunk_dir ], info[ :chunks ].shift )
          data = info[ :cache ] = IO.binread( path )

          begin
            File.delete( path )
          rescue Errno::ENOENT
          end
        else
          data, from = info[ :wbuff ], :wbuff
        end
      end

      [ data, from ]
    end

    def add_closing( sock )
      unless @closings.include?( sock )
        @reads.delete( sock )
        @closings << sock
      end

      add_write( sock )
    end

    def add_write( sock, data = nil )
      if data
        info = @infos[ sock ]
        info[ :wbuff ] << data

        if info[ :wbuff ].size >= CHUNK_SIZE
          filename = [ info[ :filename ], info[ :chunk_seed ] ].join( '.' )
          chunk_path = File.join( info[ :chunk_dir ], filename )
          IO.binwrite( chunk_path, info[ :wbuff ] )
          info[ :chunks ] << filename
          info[ :chunk_seed ] += 1
          info[ :wbuff ].clear
        end
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
      @roles.delete( sock )
      info = @infos.delete( sock )

      if info && info[ :chunks ]
        info[ :chunks ].each do | filename |
          begin
            File.delete( File.join( info[ :chunk_dir ], filename ) )
          rescue Errno::ENOENT
          end
        end
      end

      info
    end

    def new_room
      room = Socket.new( Socket::AF_INET, Socket::SOCK_STREAM, 0 )
      room.setsockopt( Socket::SOL_SOCKET, Socket::SO_REUSEADDR, 1 )
      room.setsockopt( Socket::SOL_TCP, Socket::TCP_NODELAY, 1 )

      begin
        room.connect_nonblock( @roomd_sockaddr )
      rescue IO::WaitWritable, Errno::EINTR
      end

      title = @title.unpack( "C*" ).map{ | c | c.chr }.join
      room_info = {
        wbuff: [ [ SET_TITLE ].pack( 'C' ), title ].join,
        p2_sockaddr: nil,
        renew_p1_times: 0,
        updated_at: Time.new
      }
      @room = room
      @room_info = room_info
      @roles[ room ] = :room
      @infos[ room ] = room_info
      @reads << room
      @writes << room
    end

    def new_p1
      p1 = Socket.new( Socket::AF_INET, Socket::SOCK_STREAM, 0 )
      p1.setsockopt( Socket::SOL_SOCKET, Socket::SO_REUSEADDR, 1 )
      p1.setsockopt( Socket::SOL_TCP, Socket::TCP_NODELAY, 1 )
      p1.bind( @room.local_address ) # use the hole

      begin
        p1.connect_nonblock( @room_info[ :p2_sockaddr ] )
      rescue IO::WaitWritable, Errno::EINTR
      rescue Exception => e
        puts "connect p2 #{ e.class } #{ Time.new }"
        p1.close
        add_closing( @room )
        return
      end

      app = Socket.new( Socket::AF_INET, Socket::SOCK_STREAM, 0 )
      app.setsockopt( Socket::SOL_TCP, Socket::TCP_NODELAY, 1 )

      begin
        app.connect_nonblock( @appd_sockaddr )
      rescue IO::WaitWritable, Errno::EINTR
      end

      p1_info = {
        wbuff: '',
        cache: '',
        filename: [ Process.pid, p1.object_id ].join( '-' ),
        chunk_dir: @p1_chunk_dir,
        chunks: [],
        chunk_seed: 0,
        need_decode: true,
        need_renew: false,
        app: app
      }

      app_info = {
        wbuff: '',
        cache: '',
        filename: [ Process.pid, app.object_id ].join( '-' ),
        chunk_dir: @app_chunk_dir,
        chunks: [],
        chunk_seed: 0,
        need_encode: true,
        p1: p1
      }

      @roles[ p1 ] = :p1
      @infos[ p1 ] = p1_info
      @reads << p1
      @roles[ app ] = :app
      @infos[ app ] = app_info
      @reads << app
    end
  end
end
