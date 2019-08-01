require 'p2p2/head'
require 'p2p2/hex'
require 'p2p2/version'
require 'socket'

##
# P2p2::P2 - 内网里的任意应用，访问另一个内网里的应用服务端。p2端。
#
module P2p2
  class P2

    ##
    # roomd_host    配对服务器ip
    # roomd_port    配对服务器端口
    # appd_host     代理地址 不限制访问：'0.0.0.0'，或者只允许本地访问：'127.0.0.1'
    # appd_port     代理端口
    # title         约定的房间名
    # app_chunk_dir 文件缓存目录，缓存app来不及写的流量
    # p2_chunk_dir  文件缓存目录，缓存p2来不及写的流量
    #
    def initialize( roomd_host, roomd_port, appd_host, appd_port, title, app_chunk_dir = '/tmp', p2_chunk_dir = '/tmp' )
      @roomd_sockaddr = Socket.sockaddr_in( roomd_port, roomd_host )
      @appd_sockaddr = Socket.sockaddr_in( appd_port, appd_host )
      @title = title
      @app_chunk_dir = app_chunk_dir
      @p2_chunk_dir = p2_chunk_dir
      @hex = P2p2::Hex.new
      @mutex = Mutex.new
      @reads = []
      @writes = []
      @closings = []
      @roles = {}  # sock => :appd / :app / :room / :p2
      @infos = {}

      ctlr, ctlw = IO.pipe
      @ctlw = ctlw
      @roles[ ctlr ] = :ctlr
      @reads << ctlr

      new_appd
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
            when :appd
              read_appd( sock )
            when :app
              read_app( sock )
            when :room
              read_room( sock )
            when :p2
              read_p2( sock )
            end
          end

          ws.each do | sock |
            case @roles[ sock ]
            when :app
              write_app( sock )
            when :room
              write_room( sock )
            when :p2
              write_p2( sock )
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

          if @app && ( Time.new - @app_info[ :updated_at ] > 1800 )
            @mutex.synchronize do
              @ctlw.write( CTL_CLOSE_APP )
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
      when CTL_CLOSE_APP
        unless @app.closed?
          add_closing( @app )
        end
      end
    end

    ##
    # read appd
    #
    def read_appd( appd )
      begin
        app, _ = appd.accept_nonblock
      rescue IO::WaitReadable, Errno::EINTR
        return
      end

      if @app && !@app.closed?
        puts "app already exist, ignore"
        app.close
        return
      end

      app_info = {
        wbuff: '',
        cache: '',
        filename: [ Process.pid, app.object_id ].join( '-' ),
        chunk_dir: @app_chunk_dir,
        chunks: [],
        chunk_seed: 0,
        need_encode: true,
        rbuff: '',
        room: nil,
        reconn_room_times: 0,
        p1_sockaddr: nil,
        p2: nil,
        renew_p2_times: 0
      }
      @app = app
      @app_info = app_info
      @roles[ app ] = :app
      @infos[ app ] = app_info
      @reads << app

      new_room
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

      if info[ :need_encode ]
        data = @hex.encode( data )
        data = [ [ data.size ].pack( 'n' ), data ].join
        info[ :need_encode ] = false
      end

      if info[ :p2 ]
        add_write( info[ :p2 ], data )
      else
        info[ :rbuff ] << data
      end

      info[ :updated_at ] = Time.new
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
        raise e if @app_info[ :reconn_room_times ] >= REROOM_LIMIT
        @app_info[ :reconn_room_times ] += 1
        sleep 5
        add_closing( room )
        return
      rescue EOFError => e
        puts "read room #{ e.class } #{ Time.new }"
        sleep 5
        add_closing( room )
        return
      end

      @app_info[ :reconn_room_times ] = 0
      @app_info[ :p1_sockaddr ] = data
      @app_info[ :updated_at ] = Time.new
      new_p2
    end

    ##
    # read p2
    #
    def read_p2( p2 )
      begin
        data = p2.read_nonblock( PACK_SIZE )
      rescue IO::WaitReadable, Errno::EINTR, IO::WaitWritable
        return
      rescue Errno::ECONNREFUSED => e
        puts "read p2 #{ e.class } #{ Time.new }"

        if @app_info[ :renew_p2_times ] >= REP2P_LIMIT
          raise e
        end

        sleep 1
        add_closing( p2 )
        info = @infos[ p2 ]
        info[ :need_renew ] = true
        @app_info[ :renew_p2_times ] += 1
        return
      rescue Exception => e
        puts "read p2 #{ e.class } #{ Time.new }"
        add_closing( p2 )
        return
      end

      if @app.nil? || @app.closed?
        add_closing( p2 )
        return
      end

      info = @infos[ p2 ]

      if info[ :need_decode ]
        len = data[ 0, 2 ].unpack( 'n' ).first
        head = @hex.decode( data[ 2, len ] )
        data = head + data[ ( 2 + len )..-1 ]
        info[ :need_decode ] = false
      end

      add_write( @app, data )
      @app_info[ :updated_at ] = Time.new
    end

    ##
    # write app
    #
    def write_app( app )
      if @closings.include?( app )
        info = close_sock( app )

        if info[ :room ] && !info[ :room ].closed?
          add_closing( info[ :room ] )
        end

        if info[ :p2 ] && !info[ :p2 ].closed?
          add_closing( info[ :p2 ] )
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

    ##
    # write room
    #
    def write_room( room )
      if @closings.include?( room )
        close_sock( room )

        unless @app.closed?
          add_closing( @app )
        end

        return
      end

      info = @infos[ room ]
      room.write( info[ :wbuff ] )
      @writes.delete( room )
    end

    ##
    # write p2
    #
    def write_p2( p2 )
      if @closings.include?( p2 )
        info = close_sock( p2 )

        if info[ :need_renew ]
          new_p2
          return
        end

        unless @app_info[ :room ].closed?
          add_closing( @app_info[ :room ] )
        end

        return
      end

      info = @infos[ p2 ]
      data, from = get_buff( info )

      if data.empty?
        @writes.delete( p2 )
        return
      end

      begin
        written = p2.write_nonblock( data )
      rescue IO::WaitWritable, Errno::EINTR, IO::WaitReadable
        return
      rescue Exception => e
        add_closing( p2 )
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

    def new_appd
      appd = Socket.new( Socket::AF_INET, Socket::SOCK_STREAM, 0 )
      appd.setsockopt( Socket::SOL_SOCKET, Socket::SO_REUSEADDR, 1 )
      appd.setsockopt( Socket::SOL_TCP, Socket::TCP_NODELAY, 1 )
      appd.bind( @appd_sockaddr )
      appd.listen( 511 )

      @roles[ appd ] = :appd
      @reads << appd
    end

    def new_room
      room = Socket.new( Socket::AF_INET, Socket::SOCK_STREAM, 0 )
      room.setsockopt( Socket::SOL_SOCKET, Socket::SO_REUSEADDR, 1 )
      room.setsockopt( Socket::SOL_TCP, Socket::TCP_NODELAY, 1 )

      begin
        room.connect_nonblock( @roomd_sockaddr )
      rescue IO::WaitWritable, Errno::EINTR
      end

      bytes = @title.unpack( "C*" ).map{ | c | c.chr }.join
      room_info = {
        wbuff: [ [ PAIRING ].pack( 'C' ), bytes ].join
      }
      @roles[ room ] = :room
      @infos[ room ] = room_info
      @reads << room
      @writes << room
      @app_info[ :room ] = room
      @app_info[ :updated_at ] = Time.new
    end

    def new_p2
      p2 = Socket.new( Socket::AF_INET, Socket::SOCK_STREAM, 0 )
      p2.setsockopt( Socket::SOL_SOCKET, Socket::SO_REUSEADDR, 1 )
      p2.setsockopt( Socket::SOL_TCP, Socket::TCP_NODELAY, 1 )
      p2.bind( @app_info[ :room ].local_address ) # use the hole

      begin
        p2.connect_nonblock( @app_info[ :p1_sockaddr ] )
      rescue IO::WaitWritable, Errno::EINTR
      rescue Exception => e
        puts "connect p1 #{ e.class } #{ Time.new }"
        p2.close
        add_closing( @app_info[ :room ] )
        return
      end

      p2_info = {
        wbuff: @app_info[ :rbuff ],
        cache: '',
        filename: [ Process.pid, p2.object_id ].join( '-' ),
        chunk_dir: @p2_chunk_dir,
        chunks: [],
        chunk_seed: 0,
        need_decode: true,
        need_renew: false
      }
      @roles[ p2 ] = :p2
      @infos[ p2 ] = p2_info
      @reads << p2

      unless p2_info[ :wbuff ].empty?
        @writes << p2
      end

      @app_info[ :p2 ] = p2
    end
  end
end
