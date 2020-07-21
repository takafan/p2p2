module P2p2
  class P2Worker

    ##
    # initialize
    #
    def initialize( p2pd_host, p2pd_port, room, sdwd_host, sdwd_port, src_chunk_dir, tun_chunk_dir )
      @p2pd_addr = Socket.sockaddr_in( p2pd_port, p2pd_host )
      @room = room
      @sdwd_addr = Socket.sockaddr_in( sdwd_port, sdwd_host )
      @src_chunk_dir = src_chunk_dir
      @tun_chunk_dir = tun_chunk_dir
      @custom = P2p2::P2Custom.new
      @mutex = Mutex.new
      @reads = []
      @writes = []
      @roles = {}     # sock => :dotr / :sdwd / :src / :tun
      @src_infos = {} # src => {}

      dotr, dotw = IO.pipe
      @dotw = dotw
      add_read( dotr, :dotr )
      new_a_sdwd
    end

    ##
    # looping
    #
    def looping
      puts "#{ Time.new } looping"
      loop_heartbeat
      loop_check_status

      loop do
        rs, ws = IO.select( @reads, @writes )

        @mutex.synchronize do
          # 先写，再读
          ws.each do | sock |
            case @roles[ sock ]
            when :src
              write_src( sock )
            when :tun
              write_tun( sock )
            end
          end

          rs.each do | sock |
            case @roles[ sock ]
            when :dotr
              read_dotr( sock )
            when :sdwd
              read_sdwd( sock )
            when :src
              read_src( sock )
            when :tun
              read_tun( sock )
            end
          end
        end
      end
    rescue Interrupt => e
      puts e.class
      quit!
    end

    ##
    # quit!
    #
    def quit!
      if @tun && !@tun.closed? && @tun_info[ :tund_addr ]
        # puts "debug1 send tun fin"
        data = [ 0, TUN_FIN ].pack( 'Q>C' )
        @tun.sendmsg( data, 0, @tun_info[ :tund_addr ] )
      end

      # puts "debug1 exit"
      exit
    end

    private

    ##
    # loop heartbeat
    #
    def loop_heartbeat( check_at = Time.new )
      Thread.new do
        loop do
          sleep HEARTBEAT_INTERVAL

          @mutex.synchronize do
            now = Time.new

            if @tun && !@tun.closed? && @tun_info[ :peer_addr ]
              if @tun_info[ :tund_addr ]
                if now - check_at >= CHECK_EXPIRE_INTERVAL
                  if now - @tun_info[ :last_recv_at ] > EXPIRE_AFTER
                    puts "#{ Time.new } expire tun"
                    set_is_closing( @tun )
                  else
                    @tun_info[ :src_exts ].each do | src_id, src_ext |
                      if src_ext[ :src ].closed? && ( now - src_ext[ :last_continue_at ] > EXPIRE_AFTER )
                        puts "#{ Time.new } expire src ext"
                        del_src_ext( src_id )
                      end
                    end
                  end

                  @src_infos.each do | src, src_info |
                    if now - src_info[ :last_continue_at ] > EXPIRE_AFTER
                      puts "#{ Time.new } expire src"
                      set_is_closing( src )
                    end
                  end

                  check_at = now
                end

                # puts "debug2 heartbeat"
                add_tun_ctlmsg( pack_a_heartbeat )
                next_tick
              elsif now - @tun_info[ :created_at ] > EXPIRE_NEW
                # no tund addr
                puts "#{ Time.new } expire new tun"
                set_is_closing( @tun )
                next_tick
              end
            end
          end
        end
      end
    end

    ##
    # loop check status
    #
    def loop_check_status
      Thread.new do
        loop do
          sleep STATUS_INTERVAL

          @mutex.synchronize do
            if @tun && !@tun.closed? && @tun_info[ :tund_addr ]
              need_trigger = false

              if @tun_info[ :src_exts ].any?
                now = Time.new

                @tun_info[ :src_exts ].each do | src_id, src_ext |
                  if now - src_ext[ :last_continue_at ] < SEND_STATUS_UNTIL
                    data = [ 0, SOURCE_STATUS, src_id, src_ext[ :relay_pack_id ], src_ext[ :continue_dst_pack_id ] ].pack( 'Q>CQ>Q>Q>' )
                    add_tun_ctlmsg( data )
                    need_trigger = true
                  end
                end
              end

              if @tun_info[ :paused ] && ( @tun_info[ :src_exts ].map{ | _, src_ext | src_ext[ :wmems ].size }.sum < RESUME_BELOW )
                puts "#{ Time.new } resume tun"
                @tun_info[ :paused ] = false
                add_write( @tun )
                need_trigger = true
              end

              if need_trigger
                next_tick
              end
            end
          end
        end
      end
    end

    ##
    # loop punch peer
    #
    def loop_punch_peer
      Thread.new do
        EXPIRE_NEW.times do
          if @tun.closed?
            # puts "debug1 break loop punch peer"
            break
          end

          @mutex.synchronize do
            # puts "debug1 punch peer"
            add_tun_ctlmsg( pack_a_heartbeat, @tun_info[ :peer_addr ] )
            next_tick
          end

          sleep 1
        end
      end
    end

    ##
    # loop send a new source
    #
    def loop_send_a_new_source( src_ext, data )
      Thread.new do
        EXPIRE_NEW.times do
          if src_ext[ :src ].closed? || src_ext[ :dst_port ]
            # puts "debug1 break loop send a new source #{ src_ext[ :dst_port ] }"
            break
          end

          @mutex.synchronize do
            # puts "debug1 send a new source #{ data.inspect }"
            add_tun_ctlmsg( data )
            next_tick
          end

          sleep 1
        end
      end
    end

    ##
    # new a sdwd
    #
    def new_a_sdwd
      sdwd = Socket.new( Socket::AF_INET, Socket::SOCK_STREAM, 0 )
      sdwd.setsockopt( Socket::SOL_SOCKET, Socket::SO_REUSEADDR, 1 )

      if RUBY_PLATFORM.include?( 'linux' )
        sdwd.setsockopt( Socket::SOL_SOCKET, Socket::SO_REUSEPORT, 1 )
        sdwd.setsockopt( Socket::SOL_TCP, Socket::TCP_NODELAY, 1 )
      end

      sdwd.bind( @sdwd_addr )
      sdwd.listen( 511 )
      puts "#{ Time.new } sdwd listen on #{ sdwd.local_address.ip_port }"
      add_read( sdwd, :sdwd )
    end

    ##
    # new a tun
    #
    def new_a_tun
      tun = Socket.new( Socket::AF_INET, Socket::SOCK_DGRAM, 0 )
      tun.bind( Socket.sockaddr_in( 0, '0.0.0.0' ) )
      port = tun.local_address.ip_port
      puts "#{ Time.new } tun bind on #{ port }"

      tun_info = {
        port: port,           # 端口
        ctlmsgs: [],          # [ to_addr, data ]
        wbuffs: [],           # 写前缓存 [ src_id, pack_id, data ]
        caches: [],           # 块读出缓存 [ src_id, pack_id, data ]
        chunks: [],           # 块队列 filename
        spring: 0,            # 块后缀，结块时，如果块队列不为空，则自增，为空，则置为0
        peer_addr: nil,       # 对面地址
        tund_addr: nil,       # 连通后的tund地址
        src_exts: {},         # src额外信息 src_id => {}
        src_ids: {},          # dst_port => src_id
        paused: false,        # 是否暂停写
        resendings: [],       # 重传队列 [ src_id, pack_id ]
        created_at: Time.new, # 创建时间
        last_recv_at: nil,    # 上一次收到流量的时间，过期关闭
        is_closing: false     # 是否准备关闭
      }

      @tun = tun
      @tun_info = tun_info
      add_read( tun, :tun )
      add_tun_ctlmsg( [ '2', @room ].join, @p2pd_addr )
    end

    ##
    # pack a heartbeat
    #
    def pack_a_heartbeat
      [ 0, HEARTBEAT, rand( 128 ) ].pack( 'Q>CC' )
    end

    ##
    # is match tund addr
    #
    def is_match_tund_addr( addrinfo )
      return false unless @tun_info[ :tund_addr ]

      from_addr = addrinfo.to_sockaddr

      if from_addr != @tun_info[ :tund_addr ]
        puts "#{ Time.new } #{ addrinfo.inspect } not match #{ Addrinfo.new( @tun_info[ :tund_addr ] ).inspect }"
        return false
      end

      @tun_info[ :last_recv_at ] = Time.new

      true
    end

    ##
    # add tun ctlmsg
    #
    def add_tun_ctlmsg( data, to_addr = nil )
      unless to_addr
        to_addr = @tun_info[ :tund_addr ]
      end

      if to_addr
        @tun_info[ :ctlmsgs ] << [ to_addr, data ]
        add_write( @tun )
      end
    end

    ##
    # add tun wbuff
    #
    def add_tun_wbuff( src_id, pack_id, data )
      @tun_info[ :wbuffs ] << [ src_id, pack_id, data ]

      if @tun_info[ :wbuffs ].size >= WBUFFS_LIMIT
        spring = @tun_info[ :chunks ].size > 0 ? ( @tun_info[ :spring ] + 1 ) : 0
        filename = "#{ Process.pid }-#{ @tun_info[ :port ] }.#{ spring }"
        chunk_path = File.join( @tun_chunk_dir, filename )
        datas = @tun_info[ :wbuffs ].map{ | _src_id, _pack_id, _data | [ [ _src_id, _pack_id, _data.bytesize ].pack( 'Q>Q>n' ), _data ].join }

        begin
          IO.binwrite( chunk_path, datas.join )
        rescue Errno::ENOSPC => e
          puts "#{ Time.new } #{ e.class }, close tun"
          set_is_closing( @tun )
          return
        end

        @tun_info[ :chunks ] << filename
        @tun_info[ :spring ] = spring
        @tun_info[ :wbuffs ].clear
      end

      add_write( @tun )
    end

    ##
    # add src wbuff
    #
    def add_src_wbuff( src, data )
      src_info = @src_infos[ src ]
      src_info[ :wbuff ] << data

      if src_info[ :wbuff ].bytesize >= CHUNK_SIZE
        spring = src_info[ :chunks ].size > 0 ? ( src_info[ :spring ] + 1 ) : 0
        filename = "#{ Process.pid }-#{ src_info[ :id ] }.#{ spring }"
        chunk_path = File.join( @src_chunk_dir, filename )

        begin
          IO.binwrite( chunk_path, src_info[ :wbuff ] )
        rescue Errno::ENOSPC => e
          puts "#{ Time.new } #{ e.class }, close src"
          set_is_closing( src )
          return
        end

        src_info[ :chunks ] << filename
        src_info[ :spring ] = spring
        src_info[ :wbuff ].clear
      end

      add_write( src )
    end

    ##
    # add read
    #
    def add_read( sock, role )
      unless @reads.include?( sock )
        @reads << sock
      end

      @roles[ sock ] = role
    end

    ##
    # add write
    #
    def add_write( sock )
      if sock && !sock.closed? && !@writes.include?( sock )
        @writes << sock
      end
    end

    ##
    # set is closing
    #
    def set_is_closing( sock )
      if sock && !sock.closed?
        role = @roles[ sock ]
        # puts "debug1 set #{ role.to_s } is closing"

        case role
        when :src
          src_info = @src_infos[ sock ]
          src_info[ :is_closing ] = true
        when :tun
          @tun_info[ :is_closing ] = true
        end

        @reads.delete( sock )
        add_write( sock )
      end
    end

    ##
    # close src
    #
    def close_src( src )
      # puts "debug1 close src"
      close_sock( src )
      src_info = @src_infos.delete( src )

      src_info[ :chunks ].each do | filename |
        begin
          File.delete( File.join( @src_chunk_dir, filename ) )
        rescue Errno::ENOENT
        end
      end

      return if @tun.closed?

      src_id = src_info[ :id ]
      src_ext = @tun_info[ :src_exts ][ src_id ]
      return unless src_ext

      if src_ext[ :is_dst_closed ]
        # puts "debug1 2-3. after close src -> dst closed ? yes -> del src ext -> send fin2"
        del_src_ext( src_id )
        data = [ 0, FIN2, src_id ].pack( 'Q>CQ>' )
        add_tun_ctlmsg( data )
      else
        # puts "debug1 1-1. after close src -> dst closed ? no -> send fin1"
        data = [ 0, FIN1, src_id, src_info[ :biggest_pack_id ], src_ext[ :continue_dst_pack_id ] ].pack( 'Q>CQ>Q>Q>' )
        add_tun_ctlmsg( data )
      end
    end

    ##
    # close tun
    #
    def close_tun( tun )
      # puts "debug1 close tun"
      close_sock( tun )

      @tun_info[ :chunks ].each do | filename |
        begin
          File.delete( File.join( @tun_chunk_dir, filename ) )
        rescue Errno::ENOENT
        end
      end

      @tun_info[ :src_exts ].each{ | _, src_ext | set_is_closing( src_ext[ :src ] ) }
    end

    ##
    # close sock
    #
    def close_sock( sock )
      sock.close
      @reads.delete( sock )
      @writes.delete( sock )
      @roles.delete( sock )
    end

    ##
    # del src ext
    #
    def del_src_ext( src_id )
      src_ext = @tun_info[ :src_exts ].delete( src_id )

      if src_ext
        @tun_info[ :src_ids ].delete( src_ext[ :dst_port ] )
      end
    end

    ##
    # release wmems
    #
    def release_wmems( src_ext, completed_pack_id )
      if completed_pack_id > src_ext[ :completed_pack_id ]
        # puts "debug2 update completed pack #{ completed_pack_id }"

        pack_ids = src_ext[ :wmems ].keys.select { | pack_id | pack_id <= completed_pack_id }

        pack_ids.each do | pack_id |
          src_ext[ :wmems ].delete( pack_id )
          src_ext[ :send_ats ].delete( pack_id )
        end

        src_ext[ :completed_pack_id ] = completed_pack_id
      end
    end

    ##
    # next tick
    #
    def next_tick
      @dotw.write( '.' )
    end

    ##
    # write src
    #
    def write_src( src )
      src_info = @src_infos[ src ]
      data = src_info[ :cache ]
      from = :cache

      if data.empty?
        if src_info[ :chunks ].any?
          path = File.join( @src_chunk_dir, src_info[ :chunks ].shift )

          begin
            src_info[ :cache ] = data = IO.binread( path )
            File.delete( path )
          rescue Errno::ENOENT => e
            puts "#{ Time.new } read #{ path } #{ e.class }"
            close_src( src )
            return
          end
        else
          data = src_info[ :wbuff ]
          from = :wbuff
        end
      end

      if data.empty?
        if src_info[ :is_closing ]
          close_src( src )
        else
          @writes.delete( src )
        end

        return
      end

      begin
        written = src.write_nonblock( data )
      rescue IO::WaitWritable, Errno::EINTR
        return
      rescue Exception => e
        close_src( src )
        return
      end

      # puts "debug2 write src #{ written }"
      data = data[ written..-1 ]
      src_info[ from ] = data
      src_info[ :last_continue_at ] = Time.new
    end

    ##
    # write tun
    #
    def write_tun( tun )
      if @tun_info[ :is_closing ]
        close_tun( tun )
        return
      end

      # 传ctlmsg
      while @tun_info[ :ctlmsgs ].any?
        to_addr, data = @tun_info[ :ctlmsgs ].first

        begin
          tun.sendmsg( data, 0, to_addr )
        rescue IO::WaitWritable, Errno::EINTR
          return
        rescue Errno::EHOSTUNREACH, Errno::ENETUNREACH => e
          puts "#{ Time.new } #{ e.class }, close tun"
          close_tun( tun )
          return
        end

        @tun_info[ :ctlmsgs ].shift
      end

      # 重传
      while @tun_info[ :resendings ].any?
        src_id, pack_id = @tun_info[ :resendings ].first
        src_ext = @tun_info[ :src_exts ][ src_id ]

        if src_ext
          data = src_ext[ :wmems ][ pack_id ]

          if data
            begin
              tun.sendmsg( data, 0, @tun_info[ :tund_addr ] )
            rescue IO::WaitWritable, Errno::EINTR
              return
            rescue Errno::EHOSTUNREACH, Errno::ENETUNREACH => e
              puts "#{ Time.new } #{ e.class }, close tun"
              close_tun( tun )
              return
            end
          end
        end

        @tun_info[ :resendings ].shift
        return
      end

      # 若写后达到上限，暂停取写前
      if @tun_info[ :src_exts ].map{ | _, src_ext | src_ext[ :wmems ].size }.sum >= WMEMS_LIMIT
        unless @tun_info[ :paused ]
          puts "#{ Time.new } pause tun #{ @tun_info[ :port ] }"
          @tun_info[ :paused ] = true
        end

        @writes.delete( tun )
        return
      end

      # 取写前
      if @tun_info[ :caches ].any?
        src_id, pack_id, data = @tun_info[ :caches ].first
        from = :caches
      elsif @tun_info[ :chunks ].any?
        path = File.join( @tun_chunk_dir, @tun_info[ :chunks ].shift )

        begin
          data = IO.binread( path )
          File.delete( path )
        rescue Errno::ENOENT => e
          puts "#{ Time.new } read #{ path } #{ e.class }"
          close_tun( tun )
          return
        end

        caches = []

        until data.empty?
          _src_id, _pack_id, pack_size = data[ 0, 18 ].unpack( 'Q>Q>n' )
          caches << [ _src_id, _pack_id, data[ 18, pack_size ] ]
          data = data[ ( 18 + pack_size )..-1 ]
        end

        @tun_info[ :caches ] = caches
        src_id, pack_id, data = caches.first
        from = :caches
      elsif @tun_info[ :wbuffs ].any?
        src_id, pack_id, data = @tun_info[ :wbuffs ].first
        from = :wbuffs
      else
        @writes.delete( tun )
        return
      end

      src_ext = @tun_info[ :src_exts ][ src_id ]

      if src_ext
        if pack_id <= CONFUSE_UNTIL
          data = @custom.encode( data )
          # puts "debug1 encoded pack #{ pack_id }"
        end

        data = [ [ pack_id, src_id ].pack( 'Q>Q>' ), data ].join

        begin
          tun.sendmsg( data, 0, @tun_info[ :tund_addr ] )
        rescue IO::WaitWritable, Errno::EINTR
          return
        rescue Errno::EHOSTUNREACH, Errno::ENETUNREACH => e
          puts "#{ Time.new } #{ e.class }, close tun"
          close_tun( tun )
          return
        end

        # puts "debug2 written pack #{ pack_id }"
        now = Time.new
        src_ext[ :relay_pack_id ] = pack_id
        src_ext[ :wmems ][ pack_id ] = data
        src_ext[ :send_ats ][ pack_id ] = now
        src_ext[ :last_continue_at ] = now
      end

      @tun_info[ from ].shift
    end

    ##
    # read dotr
    #
    def read_dotr( dotr )
      dotr.read( 1 )
    end

    ##
    # read sdwd
    #
    def read_sdwd( sdwd )
      begin
        src, addrinfo = sdwd.accept_nonblock
      rescue IO::WaitReadable, Errno::EINTR
        return
      end

      id = rand( ( 2 ** 64 ) - 1 ) + 1
      # puts "debug1 accept a src #{ addrinfo.inspect } #{ id }"

      @src_infos[ src ] = {
        id: id,                     # id
        biggest_pack_id: 0,         # 最大包号码
        rbuffs: [],                 # p1端dst未准备好，暂存流量 [ pack_id, data ]
        wbuff: '',                  # 写前
        cache: '',                  # 块读出缓存
        chunks: [],                 # 块队列，写前达到块大小时结一个块 filename
        spring: 0,                  # 块后缀，结块时，如果块队列不为空，则自增，为空，则置为0
        last_continue_at: Time.new, # 上一次发生流量的时间
        is_closing: false           # 是否准备关闭
      }

      add_read( src, :src )

      if @tun.nil? || @tun.closed?
        new_a_tun
      end

      src_ext = {
        src: src,                  # src
        dst_port: nil,             # p1端dst端口
        wmems: {},                 # 写后 pack_id => data
        send_ats: {},              # 上一次发出时间 pack_id => send_at
        relay_pack_id: 0,          # 转发到几
        continue_dst_pack_id: 0,   # 收到几
        pieces: {},                # 跳号包 dst_pack_id => data
        is_dst_closed: false,      # dst是否已关闭
        biggest_dst_pack_id: 0,    # dst最大包号码
        completed_pack_id: 0,      # 完成到几（对面收到几）
        last_continue_at: Time.new # 上一次发生流量的时间
      }

      @tun_info[ :src_exts ][ id ] = src_ext
      data = [ 0, A_NEW_SOURCE, id ].pack( 'Q>CQ>' )
      loop_send_a_new_source( src_ext, data )
    end

    ##
    # read src
    #
    def read_src( src )
      begin
        data = src.read_nonblock( PACK_SIZE )
      rescue IO::WaitReadable, Errno::EINTR
        return
      rescue Exception => e
        # puts "debug1 read src #{ e.class }"
        set_is_closing( src )
        return
      end

      # puts "debug2 read src #{ data.inspect }"
      src_info = @src_infos[ src ]
      src_info[ :last_continue_at ] = Time.new
      src_id = src_info[ :id ]
      src_ext = @tun_info[ :src_exts ][ src_id ]

      unless src_ext
        # puts "debug1 not found src ext"
        set_is_closing( src )
        return
      end

      if @tun.closed?
        puts "#{ Time.new } tun closed, close src"
        set_is_closing( src )
        return
      end

      pack_id = src_info[ :biggest_pack_id ] + 1
      src_info[ :biggest_pack_id ] = pack_id

      if src_ext[ :dst_port ]
        add_tun_wbuff( src_info[ :id ], pack_id, data )
      else
        # puts "debug1 p1 dst not ready, save data to src rbuff"
        src_info[ :rbuffs ] << [ pack_id, data ]
      end
    end

    ##
    # read tun
    #
    def read_tun( tun )
      data, addrinfo, rflags, *controls = tun.recvmsg
      now = Time.new
      pack_id = data[ 0, 8 ].unpack( 'Q>' ).first

      if pack_id == 0
        ctl_num = data[ 8 ].unpack( 'C' ).first

        case ctl_num
        when PEER_ADDR
          return if @tun_info[ :peer_addr ] || ( addrinfo.to_sockaddr != @p2pd_addr )

          peer_addr = data[ 9..-1 ]
          puts "#{ Time.new } got peer addr #{ Addrinfo.new( peer_addr ).inspect }"

          @tun_info[ :peer_addr ] = peer_addr
          loop_punch_peer
        when HEARTBEAT
          from_addr = addrinfo.to_sockaddr
          return if from_addr != @tun_info[ :peer_addr ]

          # puts "debug1 set tun addr #{ Addrinfo.new( from_addr ).inspect }"
          @tun_info[ :tund_addr ] = from_addr
          @tun_info[ :last_recv_at ] = now
        when PAIRED
          return unless is_match_tund_addr( addrinfo )

          src_id, dst_port = data[ 9, 10 ].unpack( 'Q>n' )

          src_ext = @tun_info[ :src_exts ][ src_id ]
          return if src_ext.nil? || src_ext[ :dst_port ]

          src = src_ext[ :src ]
          return if src.closed?

          # puts "debug1 got paired #{ src_id } #{ dst_port }"

          if dst_port == 0
            set_is_closing( src )
            return
          end

          src_ext[ :dst_port ] = dst_port
          @tun_info[ :src_ids ][ dst_port ] = src_id

          src_info = @src_infos[ src ]

          src_info[ :rbuffs ].each do | _pack_id, _data |
            add_tun_wbuff( src_id, _pack_id, _data )
          end
        when DEST_STATUS
          return unless is_match_tund_addr( addrinfo )

          dst_port, relay_dst_pack_id, continue_src_pack_id = data[ 9, 18 ].unpack( 'nQ>Q>' )

          src_id = @tun_info[ :src_ids ][ dst_port ]
          return unless src_id

          src_ext = @tun_info[ :src_exts ][ src_id ]
          return unless src_ext

          # puts "debug2 got dest status"

          release_wmems( src_ext, continue_src_pack_id )

          # 发miss
          if !src_ext[ :src ].closed? && ( src_ext[ :continue_dst_pack_id ] < relay_dst_pack_id )
            ranges = []
            curr_pack_id = src_ext[ :continue_dst_pack_id ] + 1

            src_ext[ :pieces ].keys.sort.each do | pack_id |
              if pack_id > curr_pack_id
                ranges << [ curr_pack_id, pack_id - 1 ]
              end

              curr_pack_id = pack_id + 1
            end

            if curr_pack_id <= relay_dst_pack_id
              ranges << [ curr_pack_id, relay_dst_pack_id ]
            end

            pack_count = 0
            # puts "debug1 continue/relay #{ src_ext[ :continue_dst_pack_id ] }/#{ relay_dst_pack_id } send MISS #{ ranges.size }"

            ranges.each do | pack_id_begin, pack_id_end |
              if pack_count >= BREAK_SEND_MISS
                puts "#{ Time.new } break send miss at #{ pack_id_begin }"
                break
              end

              data2 = [ 0, MISS, dst_port, pack_id_begin, pack_id_end ].pack( 'Q>CnQ>Q>' )
              add_tun_ctlmsg( data2 )
              pack_count += ( pack_id_end - pack_id_begin + 1 )
            end
          end
        when MISS
          return unless is_match_tund_addr( addrinfo )

          src_id, pack_id_begin, pack_id_end = data[ 9, 24 ].unpack( 'Q>Q>Q>' )

          src_ext = @tun_info[ :src_exts ][ src_id ]
          return unless src_ext

          ( pack_id_begin..pack_id_end ).each do | pack_id |
            send_at = src_ext[ :send_ats ][ pack_id ]

            if send_at
              break if now - send_at < STATUS_INTERVAL
              @tun_info[ :resendings ] << [ src_id, pack_id ]
            end
          end

          add_write( tun )
        when FIN1
          return unless is_match_tund_addr( addrinfo )

          dst_port, biggest_dst_pack_id, continue_src_pack_id = data[ 9, 18 ].unpack( 'nQ>Q>' )

          src_id = @tun_info[ :src_ids ][ dst_port ]
          return unless src_id

          src_ext = @tun_info[ :src_exts ][ src_id ]
          return unless src_ext

          # puts "debug1 got fin1 #{ dst_port } biggest dst pack #{ biggest_dst_pack_id } completed src pack #{ continue_src_pack_id }"
          src_ext[ :is_dst_closed ] = true
          src_ext[ :biggest_dst_pack_id ] = biggest_dst_pack_id
          release_wmems( src_ext, continue_src_pack_id )

          if ( biggest_dst_pack_id == src_ext[ :continue_dst_pack_id ] )
            # puts "debug1 2-1. tun recv fin1 -> all traffic received ? -> close src after write"
            set_is_closing( src_ext[ :src ] )
          end
        when FIN2
          return unless is_match_tund_addr( addrinfo )

          dst_port = data[ 9, 2 ].unpack( 'n' ).first

          src_id = @tun_info[ :src_ids ][ dst_port ]
          return unless src_id

          # puts "debug1 1-2. tun recv fin2 -> del src ext"
          del_src_ext( src_id )
        when TUND_FIN
          return unless is_match_tund_addr( addrinfo )

          puts "#{ Time.new } recv tund fin"
          set_is_closing( tun )
        end

        return
      end

      return unless is_match_tund_addr( addrinfo )

      dst_port = data[ 8, 2 ].unpack( 'n' ).first

      src_id = @tun_info[ :src_ids ][ dst_port ]
      return unless src_id

      src_ext = @tun_info[ :src_exts ][ src_id ]
      return if src_ext.nil? || src_ext[ :src ].closed?
      return if ( pack_id <= src_ext[ :continue_dst_pack_id ] ) || src_ext[ :pieces ].include?( pack_id )

      data = data[ 10..-1 ]
      # puts "debug2 got pack #{ pack_id }"

      if pack_id <= CONFUSE_UNTIL
        # puts "debug2 #{ data.inspect }"
        data = @custom.decode( data )
        # puts "debug1 decoded pack #{ pack_id }"
      end

      # 放进写前，跳号放碎片缓存
      if pack_id - src_ext[ :continue_dst_pack_id ] == 1
        while src_ext[ :pieces ].include?( pack_id + 1 )
          data << src_ext[ :pieces ].delete( pack_id + 1 )
          pack_id += 1
        end

        src_ext[ :continue_dst_pack_id ] = pack_id
        src_ext[ :last_continue_at ] = now
        add_src_wbuff( src_ext[ :src ], data )
        # puts "debug2 update continue dst pack #{ pack_id }"

        # 接到流量，若对面已关闭，且流量正好收全，关闭src
        if src_ext[ :is_dst_closed ] && ( pack_id == src_ext[ :biggest_dst_pack_id ] )
          # puts "debug1 2-2. tun recv traffic -> dst closed and all traffic received ? -> close src after write"
          set_is_closing( src_ext[ :src ] )
        end
      else
        src_ext[ :pieces ][ pack_id ] = data
      end
    end

  end
end
