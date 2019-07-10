require 'p2p2/head'
require 'p2p2/hex'
require 'p2p2/version'
require 'socket'

##
# P2p2::P2 - 处于nat里的任意应用，访问处于另一个nat里的应用服务端，借助一根p2p管道。p2端。
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
      @renewings = []
      @roles = {}  # sock => :appd / :app / :room / :p2
      @infos = {}
      @retries = 0

      new_appd
    end

    def looping
      puts 'looping'

      loop do
        rs, ws = IO.select( @reads, @writes )

        @mutex.synchronize do
          rs.each do | sock |
            case @roles[ sock ]
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
            when :room
              write_room( sock )
            when :p2
              write_p2( sock )
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

          if Time.new - @room_info[ :updated_at ] > 600
            @mutex.synchronize do
              @ctlw.write( CTL_CLOSE_ROOM )
            end
          end
        end
      end
    end

    def read_appd( appd )
      begin
        app, addr = sock.accept_nonblock
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
        rbuff: ''
      }
      @app = app
      @app_info = app_info
      @roles[ app ] = :app
      @infos[ app ] = app_info
      @reads << app

      new_room
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

      if @p2.nil?
        info[ :rbuff ] << data
      # elsif @p2.closed?
      #   info[ :rbuff ] << data
      #   add_renewing( @room )
      else
        add_write( @p2, data, NEED_CHUNK )
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
      info[ :p1_sockaddr ] = data
      new_p2
    end

    def read_p2( sock )
      begin
        data = sock.read_nonblock( PACK_SIZE )
      rescue IO::WaitReadable, Errno::EINTR, IO::WaitWritable
        return
      rescue Errno::ECONNREFUSED => e
        puts "read p2 #{ e.class } #{ Time.new }"
        if @room_info[ :rep2p ] >= REP2P_LIMIT
          raise e
        end

        sleep 1
        add_renewing( sock )
        @room_info[ :rep2p ] += 1
        return
      rescue Exception => e
        puts "read p2 #{ e.class } #{ Time.new }"
        add_closing( sock )
        return
      end

      @room_info[ :rep2p ] = 0

      unless @app
        add_closing( sock )
        return
      end

      info = @infos[ sock ]

      if info[ :need_decode ]
        len = data[ 0, 2 ].unpack( 'n' ).first
        head = @hex.decode( data[ 2, len ] )
        data = head + data[ ( 2 + len )..-1 ]
        info[ :need_decode ] = false
      end

      add_write( @app, data, NEED_CHUNK )
    end

    def write_room( sock )
      if @renewings.include?( sock )
        close_sock( sock )
        @p2 = nil
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

    def write_p2( sock )
      if sock.closed?
        return
      end

      if @closings.include?( sock )
        close_sock( sock )
        return
      end

      if @renewings.include?( sock )
        close_sock( sock )
        new_p2
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
      if sock.closed?
        return
      end

      if @closings.include?( sock )
        close_sock( sock )
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
        @closings << sock
      end

      add_write( sock )
    end

    def add_renewing( sock )
      unless @renewings.include?( sock )
        @reads.delete( sock )
        @renewings << sock
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

    def new_appd
      appd = Socket.new( Socket::AF_INET, Socket::SOCK_STREAM, 0 )
      appd.setsockopt( Socket::SOL_SOCKET, Socket::SO_REUSEADDR, 1 )
      appd.setsockopt( Socket::SOL_TCP, Socket::TCP_NODELAY, 1 )
      appd.bind( @appd_sockaddr )
      appd.listen( 511 )

      @appd = appd
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
        wbuff: [ [ PAIRING ].pack( 'C' ), bytes ].join,
        p1_sockaddr: nil,
        renew_p2_times: 0,
        updated_at: Time.new,
        p2: nil
      }
      @room = room
      @room_info = room_info
      @roles[ room ] = :room
      @infos[ room ] = room_info
      @reads << room
      @writes << room
    end

    def new_p2
      p2 = Socket.new( Socket::AF_INET, Socket::SOCK_STREAM, 0 )
      p2.setsockopt( Socket::SOL_SOCKET, Socket::SO_REUSEADDR, 1 )
      p2.setsockopt( Socket::SOL_TCP, Socket::TCP_NODELAY, 1 )
      p2.bind( @room.local_address ) # use the hole

      begin
        p2.connect_nonblock( @room_info[ :p1_sockaddr ] )
      rescue IO::WaitWritable, Errno::EINTR
      rescue Exception => e
        puts "connect p1 #{ e.class } #{ Time.new }"
        p2.close
        add_closing( @room )
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
      @room_info[ :p2 ] = p2

      unless p2_info[ :wbuff ].empty?
        @writes << p2
      end
    end
  end
end
