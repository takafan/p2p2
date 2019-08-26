require 'p2p2/head'
require 'p2p2/hex'
require 'p2p2/version'
require 'socket'

##
# P2p2::P1 - 内网里的任意应用，访问另一个内网里的应用服务端。p1端。
#
# 两套关闭
# ========
#
# 1-1. shadow.close -> ext.is_app_closed ? no -> send fin1 loop
# 1-2. recv got_fin1 -> break loop
# 1-3. recv fin2 -> send got_fin2 -> del ext
#
# 2-1. recv fin1 -> send got_fin1 -> ext.is_app_closed = true
# 2-2. all sent && ext.biggest_app_pack_id == ext.continue_app_pack_id -> add closing shadow
# 2-3. shadow.close -> ext.is_app_closed ? yes -> del ext -> loop send fin2
# 2-4. recv got_fin2 -> break loop
#
module P2p2
  class P1

    ##
    # p2pd_host        配对服务器ip
    # p2pd_port        配对服务器端口
    # appd_host        任意的一个应用的ip
    # appd_port        应用端口
    # title            约定的房间名
    # shadow_chunk_dir 文件缓存目录，缓存shadow来不及写的流量
    # p1_chunk_dir     文件缓存目录，缓存p1来不及写的流量
    #
    def initialize( p2pd_host, p2pd_port, appd_host, appd_port, title, shadow_chunk_dir = '/tmp', p1_chunk_dir = '/tmp' )
      @p2pd_sockaddr = Socket.sockaddr_in( p2pd_port, p2pd_host )
      @appd_sockaddr = Socket.sockaddr_in( appd_port, appd_host )
      @title = title
      @shadow_chunk_dir = shadow_chunk_dir
      @p1_chunk_dir = p1_chunk_dir
      @hex = P2p2::Hex.new
      @mutex = Mutex.new
      @reads = []
      @writes = []
      @closings = []
      @socks = {} # object_id => sock
      @roles = {} # sock => :ctlr / :shadow / :p1
      @infos = {} # sock => {}

      ctlr, ctlw = IO.pipe
      @ctlw = ctlw
      @roles[ ctlr ] = :ctlr
      add_read( ctlr )
    end

    def looping
      puts 'looping'

      new_p1

      loop do
        rs, ws = IO.select( @reads, @writes )

        @mutex.synchronize do
          rs.each do | sock |
            case @roles[ sock ]
            when :ctlr
              read_ctlr( sock )
            when :shadow
              read_shadow( sock )
            when :p1
              read_p1( sock )
            end
          end

          ws.each do | sock |
            case @roles[ sock ]
            when :shadow
              write_shadow( sock )
            when :p1
              write_p1( sock )
            end
          end
        end
      end
    rescue Interrupt => e
      puts e.class
      quit!
    end

    def quit!
      if @p1 && !@p1.closed? && @p1_info[ :p2_addr ]
        ctlmsg = [ 0, P1_FIN ].pack( 'Q>C' )
        send_pack( @p1, ctlmsg, @p1_info[ :p2_addr ] )
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
        sock = @socks[ sock_id ]

        if sock
          # puts "debug ctlr close #{ sock_id } #{ Time.new }"
          add_closing( sock )
        end
      when CTL_RESUME
        sock_id = ctlr.read( 8 ).unpack( 'Q>' ).first
        sock = @socks[ sock_id ]

        if sock
          puts "ctlr resume #{ sock_id } #{ Time.new }"
          add_write( sock )
        end
      end
    end

    ##
    # read shadow
    #
    def read_shadow( shadow )
      begin
        data = shadow.read_nonblock( PACK_SIZE )
      rescue IO::WaitReadable, Errno::EINTR
        return
      rescue Exception => e
        add_closing( shadow )
        return
      end

      info = @infos[ shadow ]
      p1 = info[ :p1 ]

      if p1.closed?
        add_closing( shadow )
        return
      end

      p1_info = @infos[ p1 ]
      p1_info[ :wbuffs ] << [ shadow.object_id, data ]

      if p1_info[ :wbuffs ].size >= WBUFFS_LIMIT
        spring = p1_info[ :chunks ].size > 0 ? ( p1_info[ :spring ] + 1 ) : 0
        filename = "#{ p1.object_id }.#{ spring }"
        chunk_path = File.join( @p1_chunk_dir, filename )
        IO.binwrite( chunk_path, p1_info[ :wbuffs ].map{ | shadow_id, data | "#{ [ shadow_id, data.bytesize ].pack( 'Q>n' ) }#{ data }" }.join )
        p1_info[ :chunks ] << filename
        p1_info[ :spring ] = spring
        p1_info[ :wbuffs ].clear
      end

      if p1_info[ :p2_addr ] && !p1_info[ :paused ]
        add_write( p1 )
      end
    end

    ##
    # read p1
    #
    def read_p1( p1 )
      data, addrinfo, rflags, *controls = p1.recvmsg
      sockaddr = addrinfo.to_sockaddr
      now = Time.new
      info = @infos[ p1 ]
      app_id = data[ 0, 8 ].unpack( 'Q>' ).first

      if app_id == 0
        case data[ 8 ].unpack( 'C' ).first
        when PEER_ADDR
          return if sockaddr != @p2pd_sockaddr

          unless info[ :p2_addr ]
            # puts "debug peer addr #{ data[ 9..-1 ].inspect } #{ Time.new }"
            info[ :p2_addr ] = data[ 9..-1 ]
            info[ :last_traffic_at ] = now
            add_write( p1 )
            loop_send_status( p1 )
          end

          ctlmsg = [ 0, HEARTBEAT, rand( 128 ) ].pack( 'Q>CC' )
          send_pack( p1, ctlmsg, info[ :p2_addr ] )
        when A_NEW_APP
          return if sockaddr != info[ :p2_addr ]

          app_id = data[ 9, 8 ].unpack( 'Q>' ).first
          shadow_id = info[ :app_ids ][ app_id ]

          unless shadow_id
            shadow = Socket.new( Socket::AF_INET, Socket::SOCK_STREAM, 0 )
            shadow.setsockopt( Socket::SOL_TCP, Socket::TCP_NODELAY, 1 )

            begin
              shadow.connect_nonblock( @appd_sockaddr )
            rescue IO::WaitWritable, Errno::EINTR
            end

            shadow_id = shadow.object_id

            @socks[ shadow_id ] = shadow
            @roles[ shadow ] = :shadow
            @infos[ shadow ] = {
              p1: p1
            }

            info[ :shadow_exts ][ shadow_id ] = {
              shadow: shadow,
              wbuff: '',               # 写前缓存
              cache: '',               # 块读出缓存
              chunks: [],              # 块队列，写前达到块大小时结一个块 filename
              spring: 0,               # 块后缀，结块时，如果块队列不为空，则自增，为空，则置为0
              wmems: {},               # 写后缓存 pack_id => data
              send_ats: {},            # 上一次发出时间 pack_id => send_at
              biggest_pack_id: 0,      # 发到几
              continue_app_pack_id: 0, # 收到几
              pieces: {},              # 跳号包 app_pack_id => data
              app_id: app_id,          # 对面id
              is_app_closed: false,    # 对面是否已关闭
              biggest_app_pack_id: 0,  # 对面发到几
              completed_pack_id: 0,    # 完成到几（对面收到几）
              last_traffic_at: nil     # 有收到有效流量，或者发出流量的时间戳
            }
            info[ :app_ids ][ app_id ] = shadow_id
            add_read( shadow )
          end

          ctlmsg = [
            0,
            PAIRED,
            app_id,
            shadow_id
          ].pack( 'Q>CQ>Q>' )

          # puts "debug send PAIRED #{ app_id } #{ shadow_id } #{ Time.new }"
          send_pack( p1, ctlmsg, info[ :p2_addr ] )
        when APP_STATUS
          return if sockaddr != info[ :p2_addr ]

          app_id, biggest_app_pack_id, continue_shadow_pack_id  = data[ 9, 24 ].unpack( 'Q>Q>Q>' )
          shadow_id = info[ :app_ids ][ app_id ]
          return unless shadow_id

          ext = info[ :shadow_exts ][ shadow_id ]
          return unless ext

          # 更新对面发到几
          if biggest_app_pack_id > ext[ :biggest_app_pack_id ]
            ext[ :biggest_app_pack_id ] = biggest_app_pack_id
          end

          # 更新对面收到几，释放写后
          if continue_shadow_pack_id > ext[ :completed_pack_id ]
            pack_ids = ext[ :wmems ].keys.select { | pack_id | pack_id <= continue_shadow_pack_id }

            pack_ids.each do | pack_id |
              ext[ :wmems ].delete( pack_id )
              ext[ :send_ats ].delete( pack_id )
            end

            ext[ :completed_pack_id ] = continue_shadow_pack_id
          end

          if ext[ :is_app_closed ] && ( ext[ :biggest_app_pack_id ] == ext[ :continue_app_pack_id ] )
            add_write( ext[ :shadow ] )
            return
          end

          # 发miss
          if !ext[ :shadow ].closed? && ( ext[ :continue_app_pack_id ] < ext[ :biggest_app_pack_id ] )
            ranges = []
            curr_pack_id = ext[ :continue_app_pack_id ] + 1

            ext[ :pieces ].keys.sort.each do | pack_id |
              if pack_id > curr_pack_id
                ranges << [ curr_pack_id, pack_id - 1 ]
              end

              curr_pack_id = pack_id + 1
            end

            if curr_pack_id <= ext[ :biggest_app_pack_id ]
              ranges << [ curr_pack_id, ext[ :biggest_app_pack_id ] ]
            end

            # puts "debug #{ ext[ :continue_app_pack_id ] }/#{ ext[ :biggest_app_pack_id ] } send MISS #{ ranges.size }"
            ranges.each do | pack_id_begin, pack_id_end |
              ctlmsg = [
                0,
                MISS,
                app_id,
                pack_id_begin,
                pack_id_end
              ].pack( 'Q>CQ>Q>Q>' )

              send_pack( p1, ctlmsg, info[ :p2_addr ] )
            end
          end
        when MISS
          return if sockaddr != info[ :p2_addr ]

          shadow_id, pack_id_begin, pack_id_end = data[ 9, 24 ].unpack( 'Q>Q>Q>' )
          ext = info[ :shadow_exts ][ shadow_id ]
          return unless ext

          ( pack_id_begin..pack_id_end ).each do | pack_id |
            send_at = ext[ :send_ats ][ pack_id ]

            if send_at
              break if now - send_at < STATUS_INTERVAL

              info[ :resendings ] << [ shadow_id, pack_id ]
            end
          end

          add_write( p1 )
        when FIN1
          return if sockaddr != info[ :p2_addr ]

          app_id = data[ 9, 8 ].unpack( 'Q>' ).first
          ctlmsg = [
            0,
            GOT_FIN1,
            app_id
          ].pack( 'Q>CQ>' )

          # puts "debug 2-1. recv fin1 -> send got_fin1 -> ext.is_app_closed = true #{ app_id } #{ Time.new }"
          send_pack( p1, ctlmsg, info[ :p2_addr ] )

          shadow_id = info[ :app_ids ][ app_id ]
          return unless shadow_id

          ext = info[ :shadow_exts ][ shadow_id ]
          return unless ext

          ext[ :is_app_closed ] = true
        when GOT_FIN1
          return if sockaddr != info[ :p2_addr ]

          # puts "debug 1-2. recv got_fin1 -> break loop #{ Time.new }"
          shadow_id = data[ 9, 8 ].unpack( 'Q>' ).first
          info[ :fin1s ].delete( shadow_id )
        when FIN2
          return if sockaddr != info[ :p2_addr ]

          # puts "debug 1-3. recv fin2 -> send got_fin2 -> del ext #{ Time.new }"
          app_id = data[ 9, 8 ].unpack( 'Q>' ).first
          ctlmsg = [
            0,
            GOT_FIN2,
            app_id
          ].pack( 'Q>CQ>' )

          send_pack( p1, ctlmsg, info[ :p2_addr ] )

          shadow_id = info[ :app_ids ].delete( app_id )
          return unless shadow_id

          del_shadow_ext( info, shadow_id )
        when GOT_FIN2
          return if sockaddr != info[ :p2_addr ]

          # puts "debug 2-4. recv got_fin2 -> break loop #{ Time.new }"
          shadow_id = data[ 9, 8 ].unpack( 'Q>' ).first
          info[ :fin2s ].delete( shadow_id )
        when P2_FIN
          return if sockaddr != info[ :p2_addr ]

          puts "recv p2 fin #{ Time.new }"
          add_closing( p1 )
        end

        return
      end

      shadow_id = info[ :app_ids ][ app_id ]
      return unless shadow_id

      ext = info[ :shadow_exts ][ shadow_id ]
      return if ext.nil? || ext[ :shadow ].closed?

      pack_id = data[ 8, 8 ].unpack( 'Q>' ).first
      return if ( pack_id <= ext[ :continue_app_pack_id ] ) || ext[ :pieces ].include?( pack_id )

      data = data[ 16..-1 ]

      # 解混淆
      if pack_id == 1
        data = @hex.decode( data )
      end

      # 放进shadow的写前缓存，跳号放碎片缓存
      if pack_id - ext[ :continue_app_pack_id ] == 1
        while ext[ :pieces ].include?( pack_id + 1 )
          data << ext[ :pieces ].delete( pack_id + 1 )
          pack_id += 1
        end

        ext[ :continue_app_pack_id ] = pack_id
        ext[ :wbuff ] << data

        if ext[ :wbuff ].bytesize >= CHUNK_SIZE
          spring = ext[ :chunks ].size > 0 ? ( ext[ :spring ] + 1 ) : 0
          filename = "#{ shadow_id }.#{ spring }"
          chunk_path = File.join( @shadow_chunk_dir, filename )
          IO.binwrite( chunk_path, ext[ :wbuff ] )
          ext[ :chunks ] << filename
          ext[ :spring ] = spring
          ext[ :wbuff ].clear
        end

        add_write( ext[ :shadow ] )
        ext[ :last_traffic_at ] = now
        info[ :last_traffic_at ] = now
      else
        ext[ :pieces ][ pack_id ] = data
      end
    end

    ##
    # write shadow
    #
    def write_shadow( shadow )
      if @closings.include?( shadow )
        close_shadow( shadow )
        return
      end

      info = @infos[ shadow ]
      p1 = info[ :p1 ]

      if p1.closed?
        add_closing( shadow )
        return
      end

      p1_info = @infos[ p1 ]
      ext = p1_info[ :shadow_exts ][ shadow.object_id ]

      # 取写前
      data = ext[ :cache ]
      from = :cache

      if data.empty?
        if ext[ :chunks ].any?
          path = File.join( @shadow_chunk_dir, ext[ :chunks ].shift )

          begin
            data = IO.binread( path )
            File.delete( path )
          rescue Errno::ENOENT
            add_closing( shadow )
            return
          end
        else
          data = ext[ :wbuff ]
          from = :wbuff
        end
      end

      if data.empty?
        if ext[ :is_app_closed ] && ( ext[ :biggest_app_pack_id ] == ext[ :continue_app_pack_id ] )
          # puts "debug 2-2. all sent && ext.biggest_app_pack_id == ext.continue_app_pack_id -> add closing shadow #{ Time.new }"
          add_closing( shadow )
          return
        end

        @writes.delete( shadow )
        return
      end

      begin
        written = shadow.write_nonblock( data )
      rescue IO::WaitWritable, Errno::EINTR => e
        ext[ from ] = data
        return
      rescue Exception => e
        add_closing( shadow )
        return
      end

      data = data[ written..-1 ]
      ext[ from ] = data
    end

    ##
    # write p1
    #
    def write_p1( p1 )
      if @closings.include?( p1 )
        close_p1( p1 )
        new_p1
        return
      end

      now = Time.new
      info = @infos[ p1 ]

      # 重传
      while info[ :resendings ].any?
        shadow_id, pack_id = info[ :resendings ].shift
        ext = info[ :shadow_exts ][ shadow_id ]

        if ext
          pack = ext[ :wmems ][ pack_id ]

          if pack
            send_pack( p1, pack, info[ :p2_addr ] )
            ext[ :last_traffic_at ] = now
            info[ :last_traffic_at ] = now
            return
          end
        end
      end

      # 若写后到达上限，暂停取写前
      if info[ :shadow_exts ].map{ | _, ext | ext[ :wmems ].size }.sum >= WMEMS_LIMIT
        unless info[ :paused ]
          puts "pause #{ Time.new }"
          info[ :paused ] = true
        end

        @writes.delete( p1 )
        return
      end

      # 取写前
      if info[ :caches ].any?
        shadow_id, data = info[ :caches ].shift
      elsif info[ :chunks ].any?
        path = File.join( @p1_chunk_dir, info[ :chunks ].shift )

        begin
          data = IO.binread( path )
          File.delete( path )
        rescue Errno::ENOENT
          add_closing( p1 )
          return
        end

        caches = []

        until data.empty?
          shadow_id, pack_size = data[ 0, 10 ].unpack( 'Q>n' )
          caches << [ shadow_id, data[ 10, pack_size ] ]
          data = data[ ( 10 + pack_size )..-1 ]
        end

        shadow_id, data = caches.shift
        info[ :caches ] = caches
      elsif info[ :wbuffs ].any?
        shadow_id, data = info[ :wbuffs ].shift
      else
        @writes.delete( p1 )
        return
      end

      ext = info[ :shadow_exts ][ shadow_id ]

      if ext
        pack_id = ext[ :biggest_pack_id ] + 1

        if pack_id == 1
          data = @hex.encode( data )
        end

        pack = "#{ [ shadow_id, pack_id ].pack( 'Q>Q>' ) }#{ data }"
        send_pack( p1, pack, info[ :p2_addr ] )
        ext[ :biggest_pack_id ] = pack_id
        ext[ :wmems ][ pack_id ] = pack
        ext[ :send_ats ][ pack_id ] = now
        ext[ :last_traffic_at ] = now
        info[ :last_traffic_at ] = now
      end
    end

    def new_p1
      p1 = Socket.new( Socket::AF_INET, Socket::SOCK_DGRAM, 0 )
      p1.setsockopt( Socket::SOL_SOCKET, Socket::SO_REUSEADDR, 1 )
      p1.bind( Socket.sockaddr_in( 0, '0.0.0.0' ) )

      p1_info = {
        wbuffs: [],          # 写前缓存 [ shadow_id, data ]
        caches: [],          # 块读出缓存 [ shadow_id, data ]
        chunks: [],          # 块队列 filename
        spring: 0,           # 块后缀，结块时，如果块队列不为空，则自增，为空，则置为0
        p2_addr: nil,        # 远端地址
        app_ids: {},         # app_id => shadow_id
        shadow_exts: {},     # 长命信息 shadow_id => {}
        fin1s: [],           # fin1: shadow已关闭，等待对面收完流量 shadow_id
        fin2s: [],           # fin2: 流量已收完 shadow_id
        paused: false,       # 是否暂停写
        resendings: [],      # 重传队列 [ shadow_id, pack_id ]
        last_traffic_at: nil # 有收到有效流量，或者发出流量的时间戳
      }

      @p1 = p1
      @p1_info = p1_info
      @socks[ p1.object_id ] = p1
      @roles[ p1 ] = :p1
      @infos[ p1 ] = p1_info

      send_pack( p1, @title, @p2pd_sockaddr )
      add_read( p1 )
      loop_expire( p1 )
    end

    def loop_expire( p1 )
      Thread.new do
        loop do
          sleep 30

          break if p1.closed?

          p1_info = @infos[ p1 ]

          if p1_info[ :p2_addr ].nil? || ( Time.new - p1_info[ :last_traffic_at ] > EXPIRE_AFTER )
            @mutex.synchronize do
              @ctlw.write( [ CTL_CLOSE, p1.object_id ].pack( 'CQ>' ) )
            end
          else
            @mutex.synchronize do
              ctlmsg = [ 0, HEARTBEAT, rand( 128 ) ].pack( 'Q>CC' )
              send_pack( p1, ctlmsg, p1_info[ :p2_addr ] )
            end
          end
        end
      end
    end

    def loop_send_status( p1 )
      Thread.new do
        loop do
          sleep STATUS_INTERVAL

          if p1.closed?
            # puts "debug p1 is closed, break send status loop #{ Time.new }"
            break
          end

          p1_info = @infos[ p1 ]

          if p1_info[ :shadow_exts ].any?
            @mutex.synchronize do
              now = Time.new

              p1_info[ :shadow_exts ].each do | shadow_id, ext |
                if ext[ :last_traffic_at ] && ( now - ext[ :last_traffic_at ] < SEND_STATUS_UNTIL )
                  ctlmsg = [
                    0,
                    SHADOW_STATUS,
                    shadow_id,
                    ext[ :biggest_pack_id ],
                    ext[ :continue_app_pack_id ]
                  ].pack( 'Q>CQ>Q>Q>' )

                  send_pack( p1, ctlmsg, p1_info[ :p2_addr ] )
                end
              end
            end
          end

          if p1_info[ :paused ] && ( p1_info[ :shadow_exts ].map{ | _, ext | ext[ :wmems ].size }.sum < RESUME_BELOW )
            @mutex.synchronize do
              @ctlw.write( [ CTL_RESUME, p1.object_id ].pack( 'CQ>' ) )
              p1_info[ :paused ] = false
            end
          end
        end
      end
    end

    def loop_send_fin1( p1, shadow_id )
      Thread.new do
        100.times do
          break if p1.closed?

          p1_info = @infos[ p1 ]
          break unless p1_info[ :p2_addr ]

          unless p1_info[ :fin1s ].include?( shadow_id )
            # puts "debug break send fin1 loop #{ Time.new }"
            break
          end

          @mutex.synchronize do
            ctlmsg = [
              0,
              FIN1,
              shadow_id
            ].pack( 'Q>CQ>' )

            # puts "debug send FIN1 #{ shadow_id } #{ Time.new }"
            send_pack( p1, ctlmsg, p1_info[ :p2_addr ] )
          end

          sleep 1
        end
      end
    end

    def loop_send_fin2( p1, shadow_id )
      Thread.new do
        100.times do
          break if p1.closed?

          p1_info = @infos[ p1 ]
          break unless p1_info[ :p2_addr ]

          unless p1_info[ :fin2s ].include?( shadow_id )
            # puts "debug break send fin2 loop #{ Time.new }"
            break
          end

          @mutex.synchronize do
            ctlmsg = [
              0,
              FIN2,
              shadow_id
            ].pack( 'Q>CQ>' )

            # puts "debug send FIN2 #{ shadow_id } #{ Time.new }"
            send_pack( p1, ctlmsg, p1_info[ :p2_addr ] )
          end

          sleep 1
        end
      end
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

    def close_p1( p1 )
      info = close_sock( p1 )

      info[ :chunks ].each do | filename |
        begin
          File.delete( File.join( @p1_chunk_dir, filename ) )
        rescue Errno::ENOENT
        end
      end

      info[ :shadow_exts ].each{ | _, ext | add_closing( ext[ :shadow ] ) }
    end

    def close_shadow( shadow )
      info = close_sock( shadow )
      p1 = info[ :p1 ]
      return if p1.closed?

      shadow_id = shadow.object_id
      p1_info = @infos[ p1 ]
      ext = p1_info[ :shadow_exts ][ shadow_id ]
      return unless ext

      if ext[ :is_app_closed ]
        del_shadow_ext( p1_info, shadow_id )

        unless p1_info[ :fin2s ].include?( shadow_id )
          # puts "debug 2-3. shadow.close -> ext.is_app_closed ? yes -> del ext -> loop send fin2 #{ Time.new }"
          p1_info[ :fin2s ] << shadow_id
          loop_send_fin2( p1, shadow_id )
        end
      elsif !p1_info[ :fin1s ].include?( shadow_id )
        # puts "debug 1-1. shadow.close -> ext.is_app_closed ? no -> send fin1 loop #{ Time.new }"
        p1_info[ :fin1s ] << shadow_id
        loop_send_fin1( p1, shadow_id )
      end
    end

    def close_sock( sock )
      sock.close
      @reads.delete( sock )
      @writes.delete( sock )
      @closings.delete( sock )
      @socks.delete( sock.object_id )
      @roles.delete( sock )
      @infos.delete( sock )
    end

    def del_shadow_ext( p1_info, shadow_id )
      ext = p1_info[ :shadow_exts ].delete( shadow_id )

      if ext
        p1_info[ :app_ids ].delete( ext[ :app_id ] )

        ext[ :chunks ].each do | filename |
          begin
            File.delete( File.join( @shadow_chunk_dir, filename ) )
          rescue Errno::ENOENT
          end
        end
      end
    end

  end
end
