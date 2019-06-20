require 'p2p2/head'
require 'p2p2/hex'
require 'p2p2/version'
require 'socket'

##
# P2p2::P1 - 处于nat里的任意应用，访问处于另一个nat里的应用服务端，借助一根p2p管道。p1端。
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
      @renewings = []
      @roles = {}  # sock => :ctlr / :room / :p1 / :app
      @infos = {}
      @retries = 0

      ctlr, ctlw = IO.pipe
      @ctlw = ctlw
      @roles[ ctlr ] = :ctlr
      @reads << ctlr

      new_room
    end

    def looping
      puts 'looping'

      loop_renew_room

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

    def loop_renew_room
      Thread.new do
        loop do
          sleep 60

          if Time.new - @room_info[ :updated_at ] > 600
            @mutex.synchronize do
              @ctlw.write( CTL_RENEW_ROOM )
            end
          end
        end
      end
    end

    def read_ctlr( sock )
      case sock.read( 1 )
      when CTL_RENEW_ROOM
        add_renewing( @room )
      end
    end

    def read_room( sock )
      begin
        data = sock.read_nonblock( PACK_SIZE )
      rescue IO::WaitReadable, Errno::EINTR, IO::WaitWritable
        return
      rescue Errno::ECONNREFUSED, EOFError, Errno::ECONNRESET => e
        puts "read room #{ e.class } #{ Time.new }"

        if @retries >= 2
          raise e
        end

        sleep 5
        add_renewing( sock )
        @retries += 1
        return
      end

      @retries = 0
      info = @infos[ sock ]
      info[ :p2_sockaddr ] = data
      info[ :updated_at ] = Time.new
      new_p1
    end

    def read_p1( sock )
      begin
        data = sock.read_nonblock( PACK_SIZE )
      rescue IO::WaitReadable, Errno::EINTR, IO::WaitWritable
        return
      rescue Errno::ECONNREFUSED => e
        if @room_info[ :rep2p ] >= REP2P_LIMIT
          raise e
        end

        sleep 1
        add_renewing( sock )
        @room_info[ :rep2p ] += 1
        return
      rescue Exception => e
        add_closing( sock )
        return
      end

      @room_info[ :rep2p ] = 0
      info = @infos[ sock ]

      if info[ :need_decode ]
        len = data[ 0, 2 ].unpack( 'n' ).first
        head = @hex.decode( data[ 2, len ] )
        data = head + data[ ( 2 + len )..-1 ]
        info[ :need_decode ] = false
      end

      add_write( @app, data, NEED_CHUNK )
    end

    def read_app( sock )
      begin
        data = sock.read_nonblock( PACK_SIZE )
      rescue IO::WaitReadable, Errno::EINTR, IO::WaitWritable
        return
      rescue Exception => e
        add_closing( sock )
        return
      end

      info = @infos[ sock ]

      if info[ :need_encode ]
        data = @hex.encode( data )
        data = [ [ data.size ].pack( 'n' ), data ].join
        info[ :need_encode ] = false
      end

      add_write( @p1, data, NEED_CHUNK )
    end

    def write_room( sock )
      if @renewings.include?( sock )
        close_sock( sock )
        new_room
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

    def write_p1( sock )
      if @closings.include?( sock )
        close_p1
        return
      end

      if @renewings.include?( sock )
        close_p1
        new_p1
        return
      end

      info = @infos[ sock ]
      data, from = get_buff( info )

      if data.empty?
        @writes.delete( sock )
        return
      end

      begin
        written = sock.write_nonblock( data )
      rescue IO::WaitWritable, Errno::EINTR, IO::WaitReadable
        return
      rescue Exception => e
        add_closing( sock )
        return
      end

      data = data[ written..-1 ]
      info[ from ] = data
    end

    def write_app( sock )
      if @closings.include?( sock )
        close_sock( sock )

        unless @p1.closed?
          add_closing( @p1 )
        end

        return
      end

      info = @infos[ sock ]
      data, from = get_buff( info )

      if data.empty?
        @writes.delete( sock )
        return
      end

      begin
        written = sock.write_nonblock( data )
      rescue IO::WaitWritable, Errno::EINTR, IO::WaitReadable
        return
      rescue Exception => e
        add_closing( sock )
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
        @closings <<  sock
      end

      add_write( sock )
    end

    def add_renewing( sock )
      unless @renewings.include?( sock )
        @reads.delete( sock )
        @renewings <<  sock
      end

      add_write( sock )
    end

    def add_write( sock, data = nil, need_chunk = false )
      if data
        info = @infos[ sock ]
        info[ :wbuff ] << data

        if need_chunk && info[ :wbuff ].size >= CHUNK_SIZE
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
      @renewings.delete( sock )
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

    def close_p1
      close_sock( @p1 )

      unless @app.closed?
        add_closing( @app )
      end
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
        wbuff: [ [ SET_TITLE, bytes.size ].pack( 'Cn' ), bytes ].join,
        p2_sockaddr: nil,
        rep2p: 0,
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
        return
      end

      p1_info = {
        wbuff: '',
        cache: '',
        filename: [ Process.pid, p1.object_id ].join( '-' ),
        chunk_dir: @p1_chunk_dir,
        chunks: [],
        chunk_seed: 0,
        need_decode: true
      }
      @p1 = p1
      @p1_info = p1_info
      @roles[ p1 ] = :p1
      @infos[ p1 ] = p1_info
      @reads << p1

      app = Socket.new( Socket::AF_INET, Socket::SOCK_STREAM, 0 )
      app.setsockopt( Socket::SOL_TCP, Socket::TCP_NODELAY, 1 )

      begin
        app.connect_nonblock( @appd_sockaddr )
      rescue IO::WaitWritable, Errno::EINTR
      end

      app_info = {
        wbuff: '',
        cache: '',
        filename: [ Process.pid, app.object_id ].join( '-' ),
        chunk_dir: @app_chunk_dir,
        chunks: [],
        chunk_seed: 0,
        need_encode: true
      }

      @app = app
      @app_info = app_info
      @roles[ app ] = :app
      @infos[ app ] = app_info
      @reads << app
    end
  end
end
