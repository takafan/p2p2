module P2p2
  class P1Worker

    ##
    # initialize
    #
    def initialize( p2pd_host, p2pd_port, room, appd_host, appd_port, dst_chunk_dir, tund_chunk_dir )
      @p2pd_addr = Socket.sockaddr_in( p2pd_port, p2pd_host )
      @room = room
      @appd_addr = Socket.sockaddr_in( appd_port, appd_host )
      @dst_chunk_dir = dst_chunk_dir
      @tund_chunk_dir = tund_chunk_dir
      @custom = P2p2::P1Custom.new
      @mutex = Mutex.new
      @reads = []
      @writes = []
      @roles = {}     # sock => :dotr / :dst / :tund
      @dst_infos = {} # dst => {}

      dotr, dotw = IO.pipe
      @dotw = dotw
      add_read( dotr, :dotr )
      new_a_tund
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
            when :dst
              write_dst( sock )
            when :tund
              write_tund( sock )
            end
          end

          rs.each do | sock |
            case @roles[ sock ]
            when :dotr
              read_dotr( sock )
            when :dst
              read_dst( sock )
            when :tund
              read_tund( sock )
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
      if !@tund.closed? && @tund_info[ :tun_addr ]
        # puts "debug1 send tund fin"
        data = [ 0, TUND_FIN ].pack( 'Q>C' )
        @tund.sendmsg( data, 0, @tund_info[ :tun_addr ] )
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

            unless @tund.closed?
              if @tund_info[ :peer_addr ]
                if @tund_info[ :tun_addr ]
                  if now - check_at >= CHECK_EXPIRE_INTERVAL
                    if now - @tund_info[ :last_recv_at ] > EXPIRE_AFTER
                      puts "#{ Time.new } expire tund"
                      set_is_closing( @tund )
                    else
                      @tund_info[ :dst_exts ].each do | dst_local_port, dst_ext |
                        if dst_ext[ :dst ].closed? && ( now - dst_ext[ :last_continue_at ] > EXPIRE_AFTER )
                          puts "#{ Time.new } expire dst ext #{ dst_local_port }"
                          del_dst_ext( dst_local_port )
                        end
                      end
                    end

                    @dst_infos.each do | dst, dst_info |
                      if dst_info[ :last_recv_at ].nil? && ( now - dst_info[ :created_at ] > EXPIRE_NEW )
                        puts "#{ Time.new } expire dst"
                        set_is_closing( dst )
                      end
                    end

                    check_at = now
                  end

                  # puts "debug2 heartbeat"
                  add_tund_ctlmsg( pack_a_heartbeat )
                  next_tick
                elsif now - @tund_info[ :last_recv_at ] > EXPIRE_NEW
                  # no tun addr
                  puts "#{ Time.new } expire new tund"
                  set_is_closing( @tund )
                  next_tick
                end
              else
                # no peer addr
                if now - check_at >= UPDATE_ROOM_INTERVAL
                  data = @room
                  check_at = now
                else
                  data = [ rand( 128 ) ].pack( 'C' )
                end

                # puts "debug2 update room"
                add_tund_ctlmsg( data, @p2pd_addr )
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
            if !@tund.closed? && @tund_info[ :tun_addr ]
              need_trigger = false

              if @tund_info[ :dst_exts ].any?
                now = Time.new

                @tund_info[ :dst_exts ].each do | dst_local_port, dst_ext |
                  if now - dst_ext[ :last_continue_at ] < SEND_STATUS_UNTIL
                    data = [ 0, DEST_STATUS, dst_local_port, dst_ext[ :relay_pack_id ], dst_ext[ :continue_src_pack_id ] ].pack( 'Q>CnQ>Q>' )
                    add_tund_ctlmsg( data )
                    need_trigger = true
                  end
                end
              end

              if @tund_info[ :paused ] && ( @tund_info[ :dst_exts ].map{ | _, dst_ext | dst_ext[ :wmems ].size }.sum < RESUME_BELOW )
                puts "#{ Time.new } resume tund"
                @tund_info[ :paused ] = false
                add_write( @tund )
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
          if @tund.closed?
            # puts "debug1 break loop punch peer"
            break
          end

          @mutex.synchronize do
            # puts "debug1 punch peer"
            add_tund_ctlmsg( pack_a_heartbeat, @tund_info[ :peer_addr ] )
            next_tick
          end

          sleep 1
        end
      end
    end

    ##
    # new a tund
    #
    def new_a_tund
      tund = Socket.new( Socket::AF_INET, Socket::SOCK_DGRAM, 0 )
      tund.bind( Socket.sockaddr_in( 0, '0.0.0.0' ) )
      port = tund.local_address.ip_port
      puts "#{ Time.new } tund bind on #{ port }"

      tund_info = {
        port: port,           # 端口
        ctlmsgs: [],          # [ to_addr, data ]
        wbuffs: [],           # 写前缓存 [ dst_local_port, pack_id, data ]
        caches: [],           # 块读出缓存 [ dst_local_port, pack_id, data ]
        chunks: [],           # 块队列 filename
        spring: 0,            # 块后缀，结块时，如果块队列不为空，则自增，为空，则置为0
        peer_addr: nil,       # 对面地址
        tun_addr: nil,        # 连通后的tun地址
        dst_exts: {},         # dst额外信息 dst_local_port => {}
        dst_local_ports: {},  # src_id => dst_local_port
        paused: false,        # 是否暂停写
        resendings: [],       # 重传队列 [ dst_local_port, pack_id ]
        created_at: Time.new, # 创建时间
        last_recv_at: nil,    # 上一次收到流量的时间，过期关闭
        is_closing: false     # 是否准备关闭
      }

      @tund = tund
      @tund_info = tund_info
      add_read( tund, :tund )
      add_tund_ctlmsg( @room, @p2pd_addr )
    end

    ##
    # pack a heartbeat
    #
    def pack_a_heartbeat
      [ 0, HEARTBEAT, rand( 128 ) ].pack( 'Q>CC' )
    end

    ##
    # is match tun addr
    #
    def is_match_tun_addr( addrinfo )
      return false unless @tund_info[ :tun_addr ]

      from_addr = addrinfo.to_sockaddr

      if from_addr != @tund_info[ :tun_addr ]
        puts "#{ Time.new } #{ addrinfo.inspect } not match #{ Addrinfo.new( @tund_info[ :tun_addr ] ).inspect }"
        return false
      end

      @tund_info[ :last_recv_at ] = Time.new

      true
    end

    ##
    # add tund ctlmsg
    #
    def add_tund_ctlmsg( data, to_addr = nil )
      unless to_addr
        to_addr = @tund_info[ :tun_addr ]
      end

      if to_addr
        @tund_info[ :ctlmsgs ] << [ to_addr, data ]
        add_write( @tund )
      end
    end

    ##
    # add tund wbuff
    #
    def add_tund_wbuff( dst_local_port, pack_id, data )
      @tund_info[ :wbuffs ] << [ dst_local_port, pack_id, data ]

      if @tund_info[ :wbuffs ].size >= WBUFFS_LIMIT
        spring = @tund_info[ :chunks ].size > 0 ? ( @tund_info[ :spring ] + 1 ) : 0
        filename = "#{ Process.pid }-#{ @tund_info[ :port ] }.#{ spring }"
        chunk_path = File.join( @tund_chunk_dir, filename )
        datas = @tund_info[ :wbuffs ].map{ | _dst_local_port, _pack_id, _data | [ [ _dst_local_port, _pack_id, _data.bytesize ].pack( 'nQ>n' ), _data ].join }

        begin
          IO.binwrite( chunk_path, datas.join )
        rescue Errno::ENOSPC => e
          puts "#{ Time.new } #{ e.class }, close tund"
          set_is_closing( @tund )
          return
        end

        @tund_info[ :chunks ] << filename
        @tund_info[ :spring ] = spring
        @tund_info[ :wbuffs ].clear
      end

      add_write( @tund )
    end

    ##
    # add dst wbuff
    #
    def add_dst_wbuff( dst, data )
      dst_info = @dst_infos[ dst ]
      dst_info[ :wbuff ] << data

      if dst_info[ :wbuff ].bytesize >= CHUNK_SIZE
        spring = dst_info[ :chunks ].size > 0 ? ( dst_info[ :spring ] + 1 ) : 0
        filename = "#{ Process.pid }-#{ dst_info[ :local_port ] }.#{ spring }"
        chunk_path = File.join( @dst_chunk_dir, filename )

        begin
          IO.binwrite( chunk_path, dst_info[ :wbuff ] )
        rescue Errno::ENOSPC => e
          puts "#{ Time.new } #{ e.class }, close dst"
          set_is_closing( dst )
          return
        end

        dst_info[ :chunks ] << filename
        dst_info[ :spring ] = spring
        dst_info[ :wbuff ].clear
      end

      add_write( dst )
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
        when :dst
          dst_info = @dst_infos[ sock ]
          dst_info[ :is_closing ] = true
        when :tund
          @tund_info[ :is_closing ] = true
        end

        @reads.delete( sock )
        add_write( sock )
      end
    end

    ##
    # close dst
    #
    def close_dst( dst )
      # puts "debug1 close dst"
      close_sock( dst )
      dst_info = @dst_infos.delete( dst )

      dst_info[ :chunks ].each do | filename |
        begin
          File.delete( File.join( @dst_chunk_dir, filename ) )
        rescue Errno::ENOENT
        end
      end

      return if @tund.closed?

      local_port = dst_info[ :local_port ]
      dst_ext = @tund_info[ :dst_exts ][ local_port ]
      return unless dst_ext

      if dst_ext[ :is_src_closed ]
        # puts "debug1 4-3. after close dst -> src closed ? yes -> del dst ext -> send fin2"
        del_dst_ext( local_port )
        data = [ 0, FIN2, local_port ].pack( 'Q>Cn' )
        add_tund_ctlmsg( data )
      else
        # puts "debug1 3-1. after close dst -> src closed ? no -> send fin1"
        data = [ 0, FIN1, local_port, dst_info[ :biggest_pack_id ], dst_ext[ :continue_src_pack_id ] ].pack( 'Q>CnQ>Q>' )
        add_tund_ctlmsg( data )
      end
    end

    ##
    # close tund
    #
    def close_tund( tund )
      # puts "debug1 close tund"
      close_sock( tund )

      @tund_info[ :chunks ].each do | filename |
        begin
          File.delete( File.join( @tund_chunk_dir, filename ) )
        rescue Errno::ENOENT
        end
      end

      @tund_info[ :dst_exts ].each{ | _, dst_ext | set_is_closing( dst_ext[ :dst ] ) }
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
    # del dst ext
    #
    def del_dst_ext( dst_local_port )
      dst_ext = @tund_info[ :dst_exts ].delete( dst_local_port )

      if dst_ext
        @tund_info[ :dst_local_ports ].delete( dst_ext[ :src_id ] )
      end
    end

    ##
    # release wmems
    #
    def release_wmems( dst_ext, completed_pack_id )
      if completed_pack_id > dst_ext[ :completed_pack_id ]
        # puts "debug2 update completed pack #{ completed_pack_id }"

        pack_ids = dst_ext[ :wmems ].keys.select { | pack_id | pack_id <= completed_pack_id }

        pack_ids.each do | pack_id |
          dst_ext[ :wmems ].delete( pack_id )
          dst_ext[ :send_ats ].delete( pack_id )
        end

        dst_ext[ :completed_pack_id ] = completed_pack_id
      end
    end

    ##
    # next tick
    #
    def next_tick
      @dotw.write( '.' )
    end

    ##
    # write dst
    #
    def write_dst( dst )
      dst_info = @dst_infos[ dst ]
      data = dst_info[ :cache ]
      from = :cache

      if data.empty?
        if dst_info[ :chunks ].any?
          path = File.join( @dst_chunk_dir, dst_info[ :chunks ].shift )

          begin
            dst_info[ :cache ] = data = IO.binread( path )
            File.delete( path )
          rescue Errno::ENOENT => e
            puts "#{ Time.new } read #{ path } #{ e.class }"
            close_dst( dst )
            return
          end
        else
          data = dst_info[ :wbuff ]
          from = :wbuff
        end
      end

      if data.empty?
        if dst_info[ :is_closing ]
          close_dst( dst )
        else
          @writes.delete( dst )
        end

        return
      end

      begin
        written = dst.write_nonblock( data )
      rescue IO::WaitWritable, Errno::EINTR
        return
      rescue Exception => e
        # puts "debug1 write dst #{ e.class }"
        close_dst( dst )
        return
      end

      # puts "debug2 write dst #{ written }"
      data = data[ written..-1 ]
      dst_info[ from ] = data
    end

    ##
    # write tund
    #
    def write_tund( tund )
      if @tund_info[ :is_closing ]
        close_tund( tund )
        new_a_tund
        return
      end

      # 传ctlmsg
      while @tund_info[ :ctlmsgs ].any?
        to_addr, data = @tund_info[ :ctlmsgs ].first

        begin
          tund.sendmsg( data, 0, to_addr )
        rescue IO::WaitWritable, Errno::EINTR
          return
        end

        @tund_info[ :ctlmsgs ].shift
      end

      # 重传
      while @tund_info[ :resendings ].any?
        dst_local_port, pack_id = @tund_info[ :resendings ].first
        dst_ext = @tund_info[ :dst_exts ][ dst_local_port ]

        if dst_ext
          data = dst_ext[ :wmems ][ pack_id ]

          if data
            begin
              tund.sendmsg( data, 0, @tund_info[ :tun_addr ] )
            rescue IO::WaitWritable, Errno::EINTR
              return
            end
          end
        end

        @tund_info[ :resendings ].shift
        return
      end

      # 若写后达到上限，暂停取写前
      if @tund_info[ :dst_exts ].map{ | _, dst_ext | dst_ext[ :wmems ].size }.sum >= WMEMS_LIMIT
        unless @tund_info[ :paused ]
          puts "#{ Time.new } pause tund #{ @tund_info[ :port ] }"
          @tund_info[ :paused ] = true
        end

        @writes.delete( tund )
        return
      end

      # 取写前
      if @tund_info[ :caches ].any?
        dst_local_port, pack_id, data = @tund_info[ :caches ].first
        from = :caches
      elsif @tund_info[ :chunks ].any?
        path = File.join( @tund_chunk_dir, @tund_info[ :chunks ].shift )

        begin
          data = IO.binread( path )
          File.delete( path )
        rescue Errno::ENOENT => e
          puts "#{ Time.new } read #{ path } #{ e.class }"
          close_tund( tund )
          return
        end

        caches = []

        until data.empty?
          _dst_local_port, _pack_id, pack_size = data[ 0, 12 ].unpack( 'nQ>n' )
          caches << [ _dst_local_port, _pack_id, data[ 12, pack_size ] ]
          data = data[ ( 12 + pack_size )..-1 ]
        end

        @tund_info[ :caches ] = caches
        dst_local_port, pack_id, data = caches.first
        from = :caches
      elsif @tund_info[ :wbuffs ].any?
        dst_local_port, pack_id, data = @tund_info[ :wbuffs ].first
        from = :wbuffs
      else
        @writes.delete( tund )
        return
      end

      dst_ext = @tund_info[ :dst_exts ][ dst_local_port ]

      if dst_ext
        if pack_id <= CONFUSE_UNTIL
          data = @custom.encode( data )
          # puts "debug1 encoded pack #{ pack_id }"
        end

        data = [ [ pack_id, dst_local_port ].pack( 'Q>n' ), data ].join

        begin
          tund.sendmsg( data, 0, @tund_info[ :tun_addr ] )
        rescue IO::WaitWritable, Errno::EINTR
          return
        end

        # puts "debug2 written pack #{ pack_id }"
        now = Time.new
        dst_ext[ :relay_pack_id ] = pack_id
        dst_ext[ :wmems ][ pack_id ] = data
        dst_ext[ :send_ats ][ pack_id ] = now
        dst_ext[ :last_continue_at ] = now
      end

      @tund_info[ from ].shift
    end

    ##
    # read dotr
    #
    def read_dotr( dotr )
      dotr.read( 1 )
    end

    ##
    # read dst
    #
    def read_dst( dst )
      begin
        data = dst.read_nonblock( PACK_SIZE )
      rescue IO::WaitReadable, Errno::EINTR
        return
      rescue Exception => e
        # puts "debug1 read dst #{ e.class }"
        set_is_closing( dst )
        return
      end

      # puts "debug2 read dst #{ data.inspect }"
      dst_info = @dst_infos[ dst ]
      dst_info[ :last_recv_at ] = Time.new

      if @tund.closed?
        puts "#{ Time.new } tund closed, close dst"
        set_is_closing( dst )
        return
      end

      pack_id = dst_info[ :biggest_pack_id ] + 1
      dst_info[ :biggest_pack_id ] = pack_id
      add_tund_wbuff( dst_info[ :local_port ], pack_id, data )
    end

    ##
    # read tund
    #
    def read_tund( tund )
      data, addrinfo, rflags, *controls = tund.recvmsg
      now = Time.new
      pack_id = data[ 0, 8 ].unpack( 'Q>' ).first

      if pack_id == 0
        ctl_num = data[ 8 ].unpack( 'C' ).first

        case ctl_num
        when PEER_ADDR
          return if @tund_info[ :peer_addr ] || ( addrinfo.to_sockaddr != @p2pd_addr )

          peer_addr = data[ 9..-1 ]
          puts "#{ Time.new } got peer addr #{ Addrinfo.new( peer_addr ).inspect }"

          @tund_info[ :peer_addr ] = peer_addr
          loop_punch_peer
        when HEARTBEAT
          from_addr = addrinfo.to_sockaddr
          return if from_addr != @tund_info[ :peer_addr ]

          # puts "debug1 set tun addr #{ Addrinfo.new( from_addr ).inspect }"
          @tund_info[ :tun_addr ] = from_addr
          @tund_info[ :last_recv_at ] = now
        when A_NEW_SOURCE
          return unless is_match_tun_addr( addrinfo )

          src_id = data[ 9, 8 ].unpack( 'Q>' ).first
          dst_local_port = @tund_info[ :dst_local_ports ][ src_id ]
          # puts "debug1 got a new source #{ src_id }"

          if dst_local_port
            dst_ext = @tund_info[ :dst_exts ][ dst_local_port ]
            return unless dst_ext

            if dst_ext[ :dst ].closed?
              dst_local_port = 0
            end
          else
            dst = Socket.new( Socket::AF_INET, Socket::SOCK_STREAM, 0 )

            if RUBY_PLATFORM.include?( 'linux' )
              dst.setsockopt( Socket::SOL_TCP, Socket::TCP_NODELAY, 1 )
            end

            begin
              dst.connect_nonblock( @appd_addr )
            rescue IO::WaitWritable
            rescue Exception => e
              puts "#{ Time.new } connect appd #{ e.class }"
              return
            end

            dst_local_port = dst.local_address.ip_port

            @dst_infos[ dst ] = {
              local_port: dst_local_port, # 本地端口
              biggest_pack_id: 0,         # 最大包号码
              wbuff: '',                  # 写前
              cache: '',                  # 块读出缓存
              chunks: [],                 # 块队列，写前达到块大小时结一个块 filename
              spring: 0,                  # 块后缀，结块时，如果块队列不为空，则自增，为空，则置为0
              created_at: Time.new,       # 创建时间
              last_recv_at: nil,          # 上一次收到流量的时间，过期关闭
              is_closing: false           # 是否准备关闭
            }
            add_read( dst, :dst )

            @tund_info[ :dst_local_ports ][ src_id ] = dst_local_port
            @tund_info[ :dst_exts ][ dst_local_port ] = {
              dst: dst,                  # dst
              src_id: src_id,            # 近端src id
              wmems: {},                 # 写后 pack_id => data
              send_ats: {},              # 上一次发出时间 pack_id => send_at
              relay_pack_id: 0,          # 转发到几
              continue_src_pack_id: 0,   # 收到几
              pieces: {},                # 跳号包 src_pack_id => data
              is_src_closed: false,      # src是否已关闭
              biggest_src_pack_id: 0,    # src最大包号码
              completed_pack_id: 0,      # 完成到几（对面收到几）
              last_continue_at: Time.new # 创建，或者上一次收到连续流量，或者发出新包的时间
            }
          end

          data2 = [ 0, PAIRED, src_id, dst_local_port ].pack( 'Q>CQ>n' )
          # puts "debug1 add ctlmsg paired #{ data2.inspect }"
          add_tund_ctlmsg( data2 )
        when SOURCE_STATUS
          return unless is_match_tun_addr( addrinfo )

          src_id, relay_src_pack_id, continue_dst_pack_id  = data[ 9, 24 ].unpack( 'Q>Q>Q>' )

          dst_local_port = @tund_info[ :dst_local_ports ][ src_id ]
          return unless dst_local_port

          dst_ext = @tund_info[ :dst_exts ][ dst_local_port ]
          return unless dst_ext

          # puts "debug2 got source status"

          release_wmems( dst_ext, continue_dst_pack_id )

          # 发miss
          if !dst_ext[ :dst ].closed? && ( dst_ext[ :continue_src_pack_id ] < relay_src_pack_id )
            ranges = []
            curr_pack_id = dst_ext[ :continue_src_pack_id ] + 1

            dst_ext[ :pieces ].keys.sort.each do | pack_id |
              if pack_id > curr_pack_id
                ranges << [ curr_pack_id, pack_id - 1 ]
              end

              curr_pack_id = pack_id + 1
            end

            if curr_pack_id <= relay_src_pack_id
              ranges << [ curr_pack_id, relay_src_pack_id ]
            end

            pack_count = 0
            # puts "debug1 continue/relay #{ dst_ext[ :continue_src_pack_id ] }/#{ relay_src_pack_id } send MISS #{ ranges.size }"

            ranges.each do | pack_id_begin, pack_id_end |
              if pack_count >= BREAK_SEND_MISS
                puts "#{ Time.new } break send miss at #{ pack_id_begin }"
                break
              end

              data2 = [ 0, MISS, src_id, pack_id_begin, pack_id_end ].pack( 'Q>CQ>Q>Q>' )
              add_tund_ctlmsg( data2 )
              pack_count += ( pack_id_end - pack_id_begin + 1 )
            end
          end
        when MISS
          return unless is_match_tun_addr( addrinfo )

          dst_local_port, pack_id_begin, pack_id_end = data[ 9, 18 ].unpack( 'nQ>Q>' )

          dst_ext = @tund_info[ :dst_exts ][ dst_local_port ]
          return unless dst_ext

          ( pack_id_begin..pack_id_end ).each do | pack_id |
            send_at = dst_ext[ :send_ats ][ pack_id ]

            if send_at
              break if now - send_at < STATUS_INTERVAL
              @tund_info[ :resendings ] << [ dst_local_port, pack_id ]
            end
          end

          add_write( tund )
        when FIN1
          return unless is_match_tun_addr( addrinfo )

          src_id, biggest_src_pack_id, continue_dst_pack_id = data[ 9, 24 ].unpack( 'Q>Q>Q>' )

          dst_local_port = @tund_info[ :dst_local_ports ][ src_id ]
          return unless dst_local_port

          dst_ext = @tund_info[ :dst_exts ][ dst_local_port ]
          return unless dst_ext

          # puts "debug1 got fin1 #{ src_id } biggest src pack #{ biggest_src_pack_id } completed dst pack #{ continue_dst_pack_id }"
          dst_ext[ :is_src_closed ] = true
          dst_ext[ :biggest_src_pack_id ] = biggest_src_pack_id
          release_wmems( dst_ext, continue_dst_pack_id )

          if biggest_src_pack_id == dst_ext[ :continue_src_pack_id ]
            # puts "debug1 4-1. tund recv fin1 -> all traffic received ? -> close dst after write"
            set_is_closing( dst_ext[ :dst ] )
          end
        when FIN2
          return unless is_match_tun_addr( addrinfo )

          src_id = data[ 9, 8 ].unpack( 'Q>' ).first

          dst_local_port = @tund_info[ :dst_local_ports ][ src_id ]
          return unless dst_local_port

          # puts "debug1 3-2. tund recv fin2 -> del dst ext"
          del_dst_ext( dst_local_port )
        when TUN_FIN
          return unless is_match_tun_addr( addrinfo )

          puts "#{ Time.new } recv tun fin"
          set_is_closing( tund )
        end

        return
      end

      return unless is_match_tun_addr( addrinfo )

      src_id = data[ 8, 8 ].unpack( 'Q>' ).first

      dst_local_port = @tund_info[ :dst_local_ports ][ src_id ]
      return unless dst_local_port

      dst_ext = @tund_info[ :dst_exts ][ dst_local_port ]
      return if dst_ext.nil? || dst_ext[ :dst ].closed?
      return if ( pack_id <= dst_ext[ :continue_src_pack_id ] ) || dst_ext[ :pieces ].include?( pack_id )

      data = data[ 16..-1 ]
      # puts "debug2 got pack #{ pack_id }"

      if pack_id <= CONFUSE_UNTIL
        # puts "debug2 #{ data.inspect }"
        data = @custom.decode( data )
        # puts "debug1 decoded pack #{ pack_id }"
      end

      # 放进写前，跳号放碎片缓存
      if pack_id - dst_ext[ :continue_src_pack_id ] == 1
        while dst_ext[ :pieces ].include?( pack_id + 1 )
          data << dst_ext[ :pieces ].delete( pack_id + 1 )
          pack_id += 1
        end

        dst_ext[ :continue_src_pack_id ] = pack_id
        dst_ext[ :last_continue_at ] = now
        add_dst_wbuff( dst_ext[ :dst ], data )
        # puts "debug2 update continue src pack #{ pack_id }"

        # 接到流量，若对面已关闭，且流量正好收全，关闭dst
        if dst_ext[ :is_src_closed ] && ( pack_id == dst_ext[ :biggest_src_pack_id ] )
          # puts "debug1 4-2. tund recv traffic -> src closed and all traffic received ? -> close dst after write"
          set_is_closing( dst_ext[ :dst ] )
          return
        end
      else
        dst_ext[ :pieces ][ pack_id ] = data
      end
    end

  end
end
