module P2p2
  class P2Worker

    ##
    # p2pd_host     配对服务器ip
    # p2pd_port     配对服务器端口
    # appd_host     代理地址 不限制访问：'0.0.0.0'，或者只允许本地访问：'127.0.0.1'
    # appd_port     代理端口
    # title         约定的房间名
    # app_chunk_dir 文件缓存目录，缓存app来不及写的流量
    # p2_chunk_dir  文件缓存目录，缓存p2来不及写的流量
    #
    def initialize( p2pd_host, p2pd_port, appd_host, appd_port, title, app_chunk_dir = '/tmp', p2_chunk_dir = '/tmp' )
      @p2pd_sockaddr = Socket.sockaddr_in( p2pd_port, p2pd_host )
      @appd_sockaddr = Socket.sockaddr_in( appd_port, appd_host )
      @title = title
      @app_chunk_dir = app_chunk_dir
      @p2_chunk_dir = p2_chunk_dir
      @hex = P2p2::Hex.new
      @mutex = Mutex.new
      @reads = []
      @writes = []
      @closings = []
      @roles = {} # sock => :ctlr / :appd / :app / :p2
      @infos = {} # sock => {}
      @socks = {} # sock => sock_id
      @sock_ids = {} # sock_id => sock

      ctlr, ctlw = IO.pipe
      @ctlw = ctlw
      @roles[ ctlr ] = :ctlr
      @reads << ctlr
    end

    def looping
      puts 'looping'

      new_appd

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
            when :p2
              read_p2( sock )
            end
          end

          ws.each do | sock |
            case @roles[ sock ]
            when :app
              write_app( sock )
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
      if @p2 && !@p2.closed? && @p2_info[ :p1_addr ]
        ctlmsg = [ 0, P2_FIN ].pack( 'Q>C' )
        send_pack( @p2, ctlmsg, @p2_info[ :p1_addr ] )
      end

      exit
    end

    private

    ##
    # read ctlr
    #
    def read_ctlr( ctlr )
      case ctlr.read( 1 ).unpack( 'C' ).first
      when CTL_CLOSE
        sock_id = ctlr.read( 8 ).unpack( 'Q>' ).first
        sock = @sock_ids[ sock_id ]

        if sock
          add_closing( sock )
        end
      when CTL_RESUME
        sock_id = ctlr.read( 8 ).unpack( 'Q>' ).first
        sock = @sock_ids[ sock_id ]

        if sock
          add_write( sock )
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

      if @p2.nil? || @p2.closed?
        new_p2
      end

      app_id = @hex.gen_random_num
      @roles[ app ] = :app
      @infos[ app ] = {
        id: app_id,
        p2: @p2
      }
      @socks[ app ] = app_id
      @sock_ids[ app_id ] = app

      @p2_info[ :waitings ][ app_id ] = []
      @p2_info[ :app_exts ][ app_id ] = {
        app: app,
        created_at: Time.new,
        last_recv_at: nil,          # 上一次收到流量的时间
        wbuff: '',                  # 写前缓存
        cache: '',                  # 块读出缓存
        chunks: [],                 # 块队列，写前达到块大小时结一个块 filename
        spring: 0,                  # 块后缀，结块时，如果块队列不为空，则自增，为空，则置为0
        wmems: {},                  # 写后缓存 pack_id => data
        send_ats: {},               # 上一次发出时间 pack_id => send_at
        biggest_pack_id: 0,         # 发到几
        continue_shadow_pack_id: 0, # 收到几
        pieces: {},                 # 跳号包 shadow_pack_id => data
        is_shadow_closed: false,    # 对面是否已关闭
        biggest_shadow_pack_id: 0,  # 对面发到几
        completed_pack_id: 0,       # 完成到几（对面收到几）
        last_traffic_at: nil        # 收到有效流量，或者发出流量的时间戳
      }

      add_read( app )
      loop_send_a_new_app( app )
    end

    ##
    # read app
    #
    def read_app( app )
      begin
        data = app.read_nonblock( PACK_SIZE )
      rescue IO::WaitReadable, Errno::EINTR
        return
      rescue Exception => e
        add_closing( app )
        return
      end

      info = @infos[ app ]
      p2 = info[ :p2 ]

      if p2.closed?
        add_closing( app )
        return
      end

      app_id = @socks[ app ]
      p2_info = @infos[ p2 ]
      shadow_id = p2_info[ :app_ids ][ app_id ]

      if p2_info[ :p1_addr ].nil? || shadow_id.nil?
        p2_info[ :waitings ][ app_id ] << data
        return
      end

      p2_info[ :wbuffs ] << [ app_id, data ]

      if p2_info[ :wbuffs ].size >= WBUFFS_LIMIT
        p2_id = @socks[ p2 ]
        spring = p2_info[ :chunks ].size > 0 ? ( p2_info[ :spring ] + 1 ) : 0
        filename = "#{ p2_id }.#{ spring }"
        chunk_path = File.join( @p2_chunk_dir, filename )
        IO.binwrite( chunk_path, p2_info[ :wbuffs ].map{ | app_id, data | "#{ [ app_id, data.bytesize ].pack( 'Q>n' ) }#{ data }" }.join )
        p2_info[ :chunks ] << filename
        p2_info[ :spring ] = spring
        p2_info[ :wbuffs ].clear
      end

      unless p2_info[ :paused ]
        add_write( p2 )
      end
    end

    ##
    # read p2
    #
    def read_p2( p2 )
      data, addrinfo, rflags, *controls = p2.recvmsg
      sockaddr = addrinfo.to_sockaddr
      now = Time.new
      info = @infos[ p2 ]
      shadow_id = data[ 0, 8 ].unpack( 'Q>' ).first

      if shadow_id == 0
        case data[ 8 ].unpack( 'C' ).first
        when PEER_ADDR
          return if info[ :peer_addr ] || ( sockaddr != @p2pd_sockaddr )

          info[ :peer_addr ] = data[ 9..-1 ]
          # puts "debug peer addr #{ Addrinfo.new( info[ :peer_addr ] ).ip_unpack.inspect } #{ Time.new }"
          loop_punch_peer( p2 )
        when HEARTBEAT
          return if info[ :p1_addr ] || ( sockaddr != info[ :peer_addr ] )

          info[ :p1_addr ] = sockaddr
          # puts "debug p1 addr #{ Addrinfo.new( info[ :p1_addr ] ).ip_unpack.inspect } #{ Time.new }"
          info[ :last_traffic_at ] = now
          loop_send_heartbeat( p2 )
          loop_check_expire( p2 )
          loop_send_status( p2 )
        when PAIRED
          return if sockaddr != info[ :p1_addr ]

          app_id, shadow_id = data[ 9, 16 ].unpack( 'Q>Q>' )
          return if info[ :app_ids ].include?( app_id )

          # puts "debug got PAIRED #{ app_id } #{ shadow_id } #{ Time.new }"
          info[ :app_ids ][ app_id ] = shadow_id
          info[ :shadow_ids ][ shadow_id ] = app_id
          buffs = info[ :waitings ][ app_id ]

          if buffs.any?
            # puts "debug move #{ buffs.size } waiting buffs to wbuffs #{ Time.new } p#{ Process.pid }"

            buffs.each do | buff |
              info[ :wbuffs ] << [ app_id, buff ]
            end

            buffs.clear
            add_write( p2 )
          end
        when SHADOW_STATUS
          return if sockaddr != info[ :p1_addr ]

          shadow_id, biggest_shadow_pack_id, continue_app_pack_id  = data[ 9, 24 ].unpack( 'Q>Q>Q>' )
          app_id = info[ :shadow_ids ][ shadow_id ]
          return unless app_id

          ext = info[ :app_exts ][ app_id ]
          return unless ext

          # 更新对面发到几
          if biggest_shadow_pack_id > ext[ :biggest_shadow_pack_id ]
            ext[ :biggest_shadow_pack_id ] = biggest_shadow_pack_id
          end

          # 更新对面收到几，释放写后
          if continue_app_pack_id > ext[ :completed_pack_id ]
            pack_ids = ext[ :wmems ].keys.select { | pack_id | pack_id <= continue_app_pack_id }

            pack_ids.each do | pack_id |
              ext[ :wmems ].delete( pack_id )
              ext[ :send_ats ].delete( pack_id )
            end

            ext[ :completed_pack_id ] = continue_app_pack_id
          end

          if ext[ :is_shadow_closed ] && ( ext[ :biggest_shadow_pack_id ] == ext[ :continue_shadow_pack_id ] )
            add_write( ext[ :app ] )
            return
          end

          # 发miss
          if !ext[ :app ].closed? && ( ext[ :continue_shadow_pack_id ] < ext[ :biggest_shadow_pack_id ] )
            ranges = []
            curr_pack_id = ext[ :continue_shadow_pack_id ] + 1

            ext[ :pieces ].keys.sort.each do | pack_id |
              if pack_id > curr_pack_id
                ranges << [ curr_pack_id, pack_id - 1 ]
              end

              curr_pack_id = pack_id + 1
            end

            if curr_pack_id <= ext[ :biggest_shadow_pack_id ]
              ranges << [ curr_pack_id, ext[ :biggest_shadow_pack_id ] ]
            end

            pack_count = 0
            # puts "debug #{ ext[ :continue_shadow_pack_id ] }/#{ ext[ :biggest_shadow_pack_id ] } send MISS #{ ranges.size }"
            ranges.each do | pack_id_begin, pack_id_end |
              if pack_count >= BREAK_SEND_MISS
                puts "break send miss at #{ pack_id_begin } #{ Time.new }"
                break
              end

              ctlmsg = [
                0,
                MISS,
                shadow_id,
                pack_id_begin,
                pack_id_end
              ].pack( 'Q>CQ>Q>Q>' )

              send_pack( p2, ctlmsg, info[ :p1_addr ] )
              pack_count += ( pack_id_end - pack_id_begin + 1 )
            end
          end
        when MISS
          return if sockaddr != info[ :p1_addr ]

          app_id, pack_id_begin, pack_id_end = data[ 9, 24 ].unpack( 'Q>Q>Q>' )
          ext = info[ :app_exts ][ app_id ]
          return unless ext

          ( pack_id_begin..pack_id_end ).each do | pack_id |
            send_at = ext[ :send_ats ][ pack_id ]

            if send_at
              break if now - send_at < STATUS_INTERVAL

              info[ :resendings ] << [ app_id, pack_id ]
            end
          end

          add_write( p2 )
        when FIN1
          return if sockaddr != info[ :p1_addr ]

          shadow_id = data[ 9, 8 ].unpack( 'Q>' ).first
          ctlmsg = [
            0,
            GOT_FIN1,
            shadow_id
          ].pack( 'Q>CQ>' )

          # puts "debug 2-1. recv fin1 -> send got_fin1 -> ext.is_shadow_closed = true #{ shadow_id } #{ Time.new }"
          send_pack( p2, ctlmsg, info[ :p1_addr ] )

          app_id = info[ :shadow_ids ][ shadow_id ]
          return unless app_id

          ext = info[ :app_exts ][ app_id ]
          return unless ext

          ext[ :is_shadow_closed ] = true
        when GOT_FIN1
          return if sockaddr != info[ :p1_addr ]

          # puts "debug 1-2. recv got_fin1 -> break loop #{ Time.new }"
          app_id = data[ 9, 8 ].unpack( 'Q>' ).first
          info[ :fin1s ].delete( app_id )
        when FIN2
          return if sockaddr != info[ :p1_addr ]

          # puts "debug 1-3. recv fin2 -> send got_fin2 -> del ext #{ Time.new }"
          shadow_id = data[ 9, 8 ].unpack( 'Q>' ).first
          ctlmsg = [
            0,
            GOT_FIN2,
            shadow_id
          ].pack( 'Q>CQ>' )

          send_pack( p2, ctlmsg, info[ :p1_addr ] )

          app_id = info[ :shadow_ids ][ shadow_id ]
          return unless app_id

          del_app_ext( info, app_id )
        when GOT_FIN2
          return if sockaddr != info[ :p1_addr ]

          # puts "debug 2-4. recv got_fin2 -> break loop #{ Time.new }"
          app_id = data[ 9, 8 ].unpack( 'Q>' ).first
          info[ :fin2s ].delete( app_id )
        when P1_FIN
          return if sockaddr != info[ :p1_addr ]
          puts "recv p1 fin #{ Time.new }"
          add_closing( p2 )
        end

        return
      end

      return if sockaddr != info[ :p1_addr ]

      app_id = info[ :shadow_ids ][ shadow_id ]
      return unless app_id

      ext = info[ :app_exts ][ app_id ]
      return if ext.nil? || ext[ :app ].closed?

      pack_id = data[ 8, 8 ].unpack( 'Q>' ).first
      return if ( pack_id <= ext[ :continue_shadow_pack_id ] ) || ext[ :pieces ].include?( pack_id )

      data = data[ 16..-1 ]

      # 解混淆
      if pack_id == 1
        data = @hex.decode( data )
      end

      # 放进shadow的写前缓存，跳号放碎片缓存
      if pack_id - ext[ :continue_shadow_pack_id ] == 1
        while ext[ :pieces ].include?( pack_id + 1 )
          data << ext[ :pieces ].delete( pack_id + 1 )
          pack_id += 1
        end

        ext[ :continue_shadow_pack_id ] = pack_id
        ext[ :wbuff ] << data

        if ext[ :wbuff ].bytesize >= CHUNK_SIZE
          spring = ext[ :chunks ].size > 0 ? ( ext[ :spring ] + 1 ) : 0
          filename = "#{ app_id }.#{ spring }"
          chunk_path = File.join( @app_chunk_dir, filename )
          IO.binwrite( chunk_path, ext[ :wbuff ] )
          ext[ :chunks ] << filename
          ext[ :spring ] = spring
          ext[ :wbuff ].clear
        end

        add_write( ext[ :app ] )
        ext[ :last_traffic_at ] = now
        info[ :last_traffic_at ] = now
      else
        ext[ :pieces ][ pack_id ] = data
      end

      ext[ :last_recv_at ] = now
    end

    ##
    # write app
    #
    def write_app( app )
      if @closings.include?( app )
        close_app( app )
        return
      end

      info = @infos[ app ]
      p2 = info[ :p2 ]

      if p2.closed?
        add_closing( app )
        return
      end

      p2_info = @infos[ p2 ]
      app_id = @socks[ app ]
      ext = p2_info[ :app_exts ][ app_id ]

      # 取写前
      data = ext[ :cache ]
      from = :cache

      if data.empty?
        if ext[ :chunks ].any?
          path = File.join( @app_chunk_dir, ext[ :chunks ].shift )

          begin
            data = IO.binread( path )
            File.delete( path )
          rescue Errno::ENOENT
            add_closing( app )
            return
          end
        else
          data = ext[ :wbuff ]
          from = :wbuff
        end
      end

      if data.empty?
        if ext[ :is_shadow_closed ] && ( ext[ :biggest_shadow_pack_id ] == ext[ :continue_shadow_pack_id ] )
          # puts "debug 2-2. all sent && ext.biggest_shadow_pack_id == ext.continue_shadow_pack_id -> add closing app #{ Time.new }"
          add_closing( app )
          return
        end

        @writes.delete( app )
        return
      end

      begin
        written = app.write_nonblock( data )
      rescue IO::WaitWritable, Errno::EINTR => e
        ext[ from ] = data
        return
      rescue Exception => e
        add_closing( app )
        return
      end

      data = data[ written..-1 ]
      ext[ from ] = data
    end

    ##
    # write p2
    #
    def write_p2( p2 )
      if @closings.include?( p2 )
        close_p2( p2 )
        return
      end

      now = Time.new
      info = @infos[ p2 ]

      # 重传
      while info[ :resendings ].any?
        app_id, pack_id = info[ :resendings ].shift
        ext = info[ :app_exts ][ app_id ]

        if ext
          pack = ext[ :wmems ][ pack_id ]

          if pack
            send_pack( p2, pack, info[ :p1_addr ] )
            ext[ :last_traffic_at ] = now
            info[ :last_traffic_at ] = now
            return
          end
        end
      end

      # 若写后达到上限，暂停取写前
      if info[ :app_exts ].map{ | _, ext | ext[ :wmems ].size }.sum >= WMEMS_LIMIT
        unless info[ :paused ]
          puts "pause #{ Time.new }"
          info[ :paused ] = true
        end

        @writes.delete( p2 )
        return
      end

      # 取写前
      if info[ :caches ].any?
        app_id, data = info[ :caches ].shift
      elsif info[ :chunks ].any?
        path = File.join( @p2_chunk_dir, info[ :chunks ].shift )

        begin
          data = IO.binread( path )
          File.delete( path )
        rescue Errno::ENOENT
          add_closing( p2 )
          return
        end

        caches = []

        until data.empty?
          app_id, pack_size = data[ 0, 10 ].unpack( 'Q>n' )
          caches << [ app_id, data[ 10, pack_size ] ]
          data = data[ ( 10 + pack_size )..-1 ]
        end

        app_id, data = caches.shift
        info[ :caches ] = caches
      elsif info[ :wbuffs ].any?
        app_id, data = info[ :wbuffs ].shift
      else
        @writes.delete( p2 )
        return
      end

      ext = info[ :app_exts ][ app_id ]

      if ext
        pack_id = ext[ :biggest_pack_id ] + 1

        if pack_id == 1
          data = @hex.encode( data )
        end

        pack = "#{ [ app_id, pack_id ].pack( 'Q>Q>' ) }#{ data }"
        send_pack( p2, pack, info[ :p1_addr ] )
        ext[ :biggest_pack_id ] = pack_id
        ext[ :wmems ][ pack_id ] = pack
        ext[ :send_ats ][ pack_id ] = now
        ext[ :last_traffic_at ] = now
        info[ :last_traffic_at ] = now
      end
    end

    def new_appd
      appd = Socket.new( Socket::AF_INET, Socket::SOCK_STREAM, 0 )
      appd.setsockopt( Socket::SOL_SOCKET, Socket::SO_REUSEADDR, 1 )
      appd.setsockopt( Socket::SOL_TCP, Socket::TCP_NODELAY, 1 )
      appd.bind( @appd_sockaddr )
      appd.listen( 511 )

      @roles[ appd ] = :appd
      add_read( appd )
    end

    def new_p2
      p2 = Socket.new( Socket::AF_INET, Socket::SOCK_DGRAM, 0 )
      p2.setsockopt( Socket::SOL_SOCKET, Socket::SO_REUSEADDR, 1 )
      p2.bind( Socket.sockaddr_in( 0, '0.0.0.0' ) )
      p2_id = @hex.gen_random_num
      p2_info = {
        id: p2_id,
        waitings: {},        # 还没连上p1，或者还没配上shadow，暂存流量 app_id => buffs[]
        wbuffs: [],          # 写前缓存 [ app_id, data ]
        caches: [],          # 块读出缓存 [ app_id, data ]
        chunks: [],          # 块队列 filename
        spring: 0,           # 块后缀，结块时，如果块队列不为空，则自增，为空，则置为0
        peer_addr: nil,      # 对面地址，连发心跳包打洞，离p2pd近的一方通常会撞死几个直到对面出来
        p1_addr: nil,        # p1地址
        app_exts: {},        # 传输相关 app_id => {}
        app_ids: {},         # app_id => shadow_id
        shadow_ids: {},      # shadow_id => app_id
        fin1s: [],           # fin1: app已关闭，等待对面收完流量 app_id
        fin2s: [],           # fin2: 流量已收完 app_id
        paused: false,       # 是否暂停写
        resendings: [],      # 重传队列 [ app_id, pack_id ]
        last_traffic_at: nil # 收到有效流量，或者发出流量的时间戳
      }

      @p2 = p2
      @p2_info = p2_info
      @roles[ p2 ] = :p2
      @infos[ p2 ] = p2_info
      @socks[ p2 ] = p2_id
      @sock_ids[ p2_id ] = p2

      send_pack( p2, @title, @p2pd_sockaddr )
      add_read( p2 )
      loop_send_char( p2 )
    end

    def loop_send_char( p2 )
      Thread.new do
        is_timeout = true

        20.times do
          sleep HEARTBEAT_INTERVAL

          if p2.closed?
            is_timeout = false
            break
          end

          p2_info = @infos[ p2 ]

          if p2_info[ :peer_addr ]
            is_timeout = false
            break
          end

          @mutex.synchronize do
            send_pack( p2, [ rand( 128 ) ].pack( 'C' ), @p2pd_sockaddr )
          end
        end

        if is_timeout
          @mutex.synchronize do
            p2_id = @socks[ p2 ]
            @ctlw.write( [ CTL_CLOSE, p2_id ].pack( 'CQ>' ) )
          end
        end
      end
    end

    def loop_punch_peer( p2 )
      Thread.new do
        20.times do
          break if p2.closed?

          p2_info = @infos[ p2 ]

          @mutex.synchronize do
            send_heartbeat( p2, p2_info[ :peer_addr ] )
          end

          sleep STATUS_INTERVAL
        end

        if !p2.closed?
          p2_info = @infos[ p2 ]

          unless p2_info[ :p1_addr ]
            @mutex.synchronize do
              p2_id = @socks[ p2 ]
              @ctlw.write( [ CTL_CLOSE, p2_id ].pack( 'CQ>' ) )
            end
          end
        end
      end
    end

    def loop_send_heartbeat( p2 )
      Thread.new do
        loop do
          sleep HEARTBEAT_INTERVAL
          break if p2.closed?

          @mutex.synchronize do
            p2_info = @infos[ p2 ]
            send_heartbeat( p2, p2_info[ :p1_addr ] )
          end
        end
      end
    end

    def loop_check_expire( p2 )
      Thread.new do
        loop do
          sleep 60
          break if p2.closed?

          now = Time.new
          p2_info = @infos[ p2 ]

          if now - p2_info[ :last_traffic_at ] > EXPIRE_AFTER
            @mutex.synchronize do
              p2_id = @socks[ p2 ]
              # puts "debug ctlw close p2 #{ p2_id } #{ Time.new } p#{ Process.pid }"
              @ctlw.write( [ CTL_CLOSE, p2_id ].pack( 'CQ>' ) )
            end

            break
          end

          exts = p2_info[ :app_exts ].select{ | _, ext | now - ext[ :created_at ] > 5 }

          if exts.any?
            @mutex.synchronize do
              exts.each do | app_id, ext |
                if ext[ :last_recv_at ].nil? || ( now - ext[ :last_recv_at ] > EXPIRE_AFTER )
                  # puts "debug ctlw close app #{ app_id } #{ Time.new } p#{ Process.pid }"
                  @ctlw.write( [ CTL_CLOSE, app_id ].pack( 'CQ>' ) )
                end
              end
            end
          end
        end
      end
    end

    def loop_send_status( p2 )
      Thread.new do
        loop do
          sleep STATUS_INTERVAL

          if p2.closed?
            # puts "debug p2 is closed, break send status loop #{ Time.new }"
            break
          end

          p2_info = @infos[ p2 ]

          if p2_info[ :app_exts ].any?
            @mutex.synchronize do
              now = Time.new

              p2_info[ :app_exts ].each do | app_id, ext |
                if ext[ :last_traffic_at ] && ( now - ext[ :last_traffic_at ] < SEND_STATUS_UNTIL )
                  ctlmsg = [
                    0,
                    APP_STATUS,
                    app_id,
                    ext[ :biggest_pack_id ],
                    ext[ :continue_shadow_pack_id ]
                  ].pack( 'Q>CQ>Q>Q>' )

                  send_pack( p2, ctlmsg, p2_info[ :p1_addr ] )
                end
              end
            end
          end

          if p2_info[ :paused ] && ( p2_info[ :app_exts ].map{ | _, ext | ext[ :wmems ].size }.sum < RESUME_BELOW )
            @mutex.synchronize do
              p2_id = @socks[ p2 ]
              puts "ctlw resume #{ p2_id } #{ Time.new }"
              @ctlw.write( [ CTL_RESUME, p2_id ].pack( 'CQ>' ) )
              p2_info[ :paused ] = false
            end
          end
        end
      end
    end

    def loop_send_fin1( p2, app_id )
      Thread.new do
        100.times do
          break if p2.closed?

          p2_info = @infos[ p2 ]
          break unless p2_info[ :p1_addr ]

          unless p2_info[ :fin1s ].include?( app_id )
            # puts "debug break send fin1 loop #{ Time.new }"
            break
          end

          @mutex.synchronize do
            ctlmsg = [
              0,
              FIN1,
              app_id
            ].pack( 'Q>CQ>' )

            # puts "debug send FIN1 #{ app_id } #{ Time.new }"
            send_pack( p2, ctlmsg, p2_info[ :p1_addr ] )
          end

          sleep 1
        end
      end
    end

    def loop_send_fin2( p2, app_id )
      Thread.new do
        100.times do
          break if p2.closed?

          p2_info = @infos[ p2 ]
          break unless p2_info[ :p1_addr ]

          unless p2_info[ :fin2s ].include?( app_id )
            # puts "debug break send fin2 loop #{ Time.new }"
            break
          end

          @mutex.synchronize do
            ctlmsg = [
              0,
              FIN2,
              app_id
            ].pack( 'Q>CQ>' )

            # puts "debug send FIN2 #{ app_id } #{ Time.new }"
            send_pack( p2, ctlmsg, p2_info[ :p1_addr ] )
          end

          sleep 1
        end
      end
    end

    def loop_send_a_new_app( app )
      Thread.new do
        100.times do
          break if app.closed?

          app_info = @infos[ app ]
          p2 = app_info[ :p2 ]
          break if p2.closed?

          p2_info = @infos[ p2 ]

          if p2_info[ :p1_addr ]
            app_id = @socks[ app ]
            shadow_id = p2_info[ :app_ids ][ app_id ]

            if shadow_id
              # puts "debug break a new app loop #{ Time.new }"
              break
            end

            @mutex.synchronize do
              ctlmsg = [ 0, A_NEW_APP, app_id ].pack( 'Q>CQ>' )
              # puts "debug send a new app #{ Time.new }"
              send_pack( p2, ctlmsg, p2_info[ :p1_addr ] )
            end
          end

          sleep 1
        end
      end
    end

    def send_heartbeat( p2, target_addr )
      ctlmsg = [ 0, HEARTBEAT, rand( 128 ) ].pack( 'Q>CC' )
      send_pack( p2, ctlmsg, target_addr )
    end

    def send_pack( sock, data, target_sockaddr )
      begin
        sock.sendmsg( data, 0, target_sockaddr )
      rescue IO::WaitWritable, Errno::EINTR => e
        puts "sendmsg #{ e.class } #{ Time.new }"
      end
    end

    def add_read( sock )
      return if sock.closed? || @reads.include?( sock )

      @reads << sock
    end

    def add_write( sock, data = nil )
      return if sock.closed? || @writes.include?( sock )

      @writes << sock
    end

    def add_closing( sock )
      return if sock.closed? || @closings.include?( sock )

      @reads.delete( sock )
      @closings << sock
      add_write( sock )
    end

    def close_p2( p2 )
      info = close_sock( p2 )

      info[ :chunks ].each do | filename |
        begin
          File.delete( File.join( @p2_chunk_dir, filename ) )
        rescue Errno::ENOENT
        end
      end

      info[ :app_exts ].each{ | _, ext | add_closing( ext[ :app ] ) }
    end

    def close_app( app )
      info = close_sock( app )
      p2 = info[ :p2 ]
      return if p2.closed?

      app_id = info[ :id ]
      p2_info = @infos[ p2 ]
      ext = p2_info[ :app_exts ][ app_id ]
      return unless ext

      ext[ :chunks ].each do | filename |
        begin
          File.delete( File.join( @app_chunk_dir, filename ) )
        rescue Errno::ENOENT
        end
      end

      if ext[ :is_shadow_closed ]
        del_app_ext( p2_info, app_id )

        unless p2_info[ :fin2s ].include?( app_id )
          # puts "debug 2-3. app.close -> ext.is_shadow_closed ? yes -> del ext -> loop send fin2 #{ Time.new }"
          p2_info[ :fin2s ] << app_id
          loop_send_fin2( p2, app_id )
        end
      elsif !p2_info[ :fin1s ].include?( app_id )
        # puts "debug 1-1. app.close -> ext.is_shadow_closed ? no -> send fin1 loop #{ Time.new }"
        p2_info[ :fin1s ] << app_id
        loop_send_fin1( p2, app_id )
      end
    end

    def close_sock( sock )
      sock.close
      @reads.delete( sock )
      @writes.delete( sock )
      @closings.delete( sock )
      @roles.delete( sock )
      info = @infos.delete( sock )
      sock_id = @socks.delete( sock )
      @sock_ids.delete( sock_id )

      info
    end

    def del_app_ext( p2_info, app_id )
      p2_info[ :waitings ].delete( app_id )
      ext = p2_info[ :app_exts ].delete( app_id )

      if ext
        ext[ :chunks ].each do | filename |
          begin
            File.delete( File.join( @app_chunk_dir, filename ) )
          rescue Errno::ENOENT
          end
        end
      end

      shadow_id = p2_info[ :app_ids ].delete( app_id )

      if shadow_id
        p2_info[ :shadow_ids ].delete( shadow_id )
      end
    end

  end
end