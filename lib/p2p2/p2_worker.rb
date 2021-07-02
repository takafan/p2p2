module P2p2
  class P2Worker

    ##
    # initialize
    #
    def initialize( paird_host, paird_port, title, shadow_host, shadow_port )
      @paird_host = paird_host
      @paird_port = paird_port
      @title = title
      @shadow_addr = Socket.sockaddr_in( shadow_port, shadow_host )
      @reads = []
      @writes = []
      @roles = {} # sock => :dotr / :shadow / :ctl / :tun / :src
      @src_infos = ConcurrentHash.new
      @tun_infos = ConcurrentHash.new

      new_a_pipe
      new_a_shadow
    end

    ##
    # looping
    #
    def looping
      puts "#{ Time.new } looping"
      loop_check_state

      loop do
        rs, ws = IO.select( @reads, @writes )

        rs.each do | sock |
          role = @roles[ sock ]

          case role
          when :dotr then
            read_dotr( sock )
          when :shadow then
            read_shadow( sock )
          when :src then
            read_src( sock )
          when :ctl then
            read_ctl( sock )
          when :tun then
            read_tun( sock )
          else
            puts "#{ Time.new } read unknown role #{ role }"
            close_sock( sock )
          end
        end

        ws.each do | sock |
          role = @roles[ sock ]

          case role
          when :tun then
            write_tun( sock )
          when :src then
            write_src( sock )
          else
            puts "#{ Time.new } write unknown role #{ role }"
            close_sock( sock )
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
      # puts "debug exit"
      exit
    end

    private

    ##
    # add read
    #
    def add_read( sock, role = nil )
      return if sock.nil? || sock.closed? || @reads.include?( sock )
      @reads << sock

      if role then
        @roles[ sock ] = role
      end
    end

    ##
    # add src rbuff
    #
    def add_src_rbuff( src, data )
      return if src.nil? || src.closed?
      src_info = @src_infos[ src ]
      src_info[ :rbuff ] << data

      if src_info[ :rbuff ].bytesize >= WBUFF_LIMIT then
        puts "#{ Time.new } src.rbuff full"
        close_src( src )
      end
    end

    ##
    # add src wbuff
    #
    def add_src_wbuff( src, data )
      return if src.nil? || src.closed?
      src_info = @src_infos[ src ]
      src_info[ :wbuff ] << data
      src_info[ :last_recv_at ] = Time.new
      add_write( src )

      if src_info[ :wbuff ].bytesize >= WBUFF_LIMIT then
        tun = src_info[ :tun ]

        if tun && !tun.closed? then
          puts "#{ Time.new } pause tun"
          @reads.delete( tun )
          tun_info = @tun_infos[ tun ]
          tun_info[ :paused ] = true
        end
      end
    end

    ##
    # add tun wbuff
    #
    def add_tun_wbuff( tun, data )
      return if tun.nil? || tun.closed?
      tun_info = @tun_infos[ tun ]
      tun_info[ :wbuff ] << data
      add_write( tun )

      if tun_info[ :wbuff ].bytesize >= WBUFF_LIMIT then
        src = tun_info[ :src ]

        if src && !src.closed? then
          puts "#{ Time.new } pause src"
          @reads.delete( src )
          src_info = @src_infos[ src ]
          src_info[ :paused ] = true
        end
      end
    end

    ##
    # add write
    #
    def add_write( sock )
      return if sock.nil? || sock.closed? || @writes.include?( sock )
      @writes << sock
    end

    ##
    # close ctl
    #
    def close_ctl
      return if @ctl.nil? || @ctl.closed?
      close_sock( @ctl )
    end

    ##
    # close read src
    #
    def close_read_src( src )
      return if src.nil? || src.closed?
      # puts "debug close read src"
      src.close_read
      @reads.delete( src )

      if src.closed? then
        # puts "debug src closed"
        @writes.delete( src )
        @roles.delete( src )
        @src_infos.delete( src )
      end
    end

    ##
    # close read tun
    #
    def close_read_tun( tun )
      return if tun.nil? || tun.closed?
      # puts "debug close read tun"
      tun.close_read
      @reads.delete( tun )

      if tun.closed? then
        # puts "debug tun closed"
        @writes.delete( tun )
        @roles.delete( tun )
        @tun_infos.delete( tun )
      end
    end

    ##
    # close sock
    #
    def close_sock( sock )
      return if sock.nil? || sock.closed?
      sock.close
      @reads.delete( sock )
      @writes.delete( sock )
      @roles.delete( sock )
    end

    ##
    # close src
    #
    def close_src( src )
      return if src.nil? || src.closed?
      puts "#{ Time.new } close src"
      close_sock( src )
      @src_infos.delete( src )
    end

    ##
    # close tun
    #
    def close_tun( tun )
      return if tun.nil? || tun.closed?
      puts "#{ Time.new } close tun"
      close_sock( tun )
      @tun_infos.delete( tun )
    end

    ##
    # close write src
    #
    def close_write_src( src )
      return if src.nil? || src.closed?
      # puts "debug close write src"
      src.close_write
      @writes.delete( src )

      if src.closed? then
        # puts "debug src closed"
        @reads.delete( src )
        @roles.delete( src )
        @src_infos.delete( src )
      end
    end

    ##
    # close write tun
    #
    def close_write_tun( tun )
      return if tun.nil? || tun.closed?
      # puts "debug close write tun"
      tun.close_write
      @writes.delete( tun )

      if tun.closed? then
        # puts "debug tun closed"
        @reads.delete( tun )
        @roles.delete( tun )
        @tun_infos.delete( tun )
      end
    end

    ##
    # loop check state
    #
    def loop_check_state
      Thread.new do
        loop do
          sleep CHECK_STATE_INTERVAL
          now = Time.new

          @src_infos.select{ | src, _ | !src.closed? }.each do | src, src_info |
            last_recv_at = src_info[ :last_recv_at ] || src_info[ :created_at ]
            last_sent_at = src_info[ :last_sent_at ] || src_info[ :created_at ]
            is_expire = ( now - last_recv_at >= EXPIRE_AFTER ) && ( now - last_sent_at >= EXPIRE_AFTER )

            if is_expire then
              puts "#{ Time.new } expire src"
              src_info[ :closing ] = true
              next_tick
            elsif src_info[ :paused ] then
              tun = src_info[ :tun ]

              if tun && !tun.closed? then
                tun_info = @tun_infos[ tun ]

                if tun_info[ :wbuff ].bytesize < RESUME_BELOW then
                  puts "#{ Time.new } resume src"
                  add_read( src )
                  src_info[ :paused ] = false
                  next_tick
                end
              end
            end
          end

          @tun_infos.select{ | tun, info | !tun.closed? && info[ :paused ] }.each do | tun, tun_info |
            src = tun_info[ :src ]

            if src && !src.closed? then
              src_info = @src_infos[ src ]

              if src_info[ :wbuff ].bytesize < RESUME_BELOW then
                puts "#{ Time.new } resume tun"
                add_read( tun )
                tun_info[ :paused ] = false
                next_tick
              end
            end
          end
        end
      end
    end

    ##
    # new a ctl
    #
    def new_a_ctl( src )
      ctl = Socket.new( Socket::AF_INET, Socket::SOCK_DGRAM, 0 )
      ctl.setsockopt( Socket::SOL_SOCKET, Socket::SO_REUSEADDR, 1 )

      if RUBY_PLATFORM.include?( 'linux' ) then
        ctl.setsockopt( Socket::SOL_SOCKET, Socket::SO_REUSEPORT, 1 )
      end

      paird_port = @paird_port + 10.times.to_a.sample
      paird_addr = Socket.sockaddr_in( paird_port, @paird_host )

      @ctl = ctl
      @ctl_info = {
        paird_addr: paird_addr,
        peer_addr: nil,
        src: src
      }

      add_read( ctl, :ctl )

      puts "#{ Time.new } find #{ @title.inspect } #{ Addrinfo.new( @ctl_info[ :paird_addr ] ).inspect }"
      send_title
    end

    ##
    # new a pipe
    #
    def new_a_pipe
      dotr, dotw = IO.pipe
      @dotw = dotw
      add_read( dotr, :dotr )
    end

    ##
    # new a shadow
    #
    def new_a_shadow
      shadow = Socket.new( Socket::AF_INET, Socket::SOCK_STREAM, 0 )
      shadow.setsockopt( Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1 )
      shadow.setsockopt( Socket::SOL_SOCKET, Socket::SO_REUSEADDR, 1 )

      if RUBY_PLATFORM.include?( 'linux' )
        shadow.setsockopt( Socket::SOL_SOCKET, Socket::SO_REUSEPORT, 1 )
      end

      shadow.bind( @shadow_addr )
      shadow.listen( 127 )
      puts "#{ Time.new } shadow listen on #{ shadow.local_address.ip_port }"
      add_read( shadow, :shadow )
    end

    ##
    # new a tun
    #
    def new_a_tun
      return if @ctl.nil? || @ctl.closed? || @ctl_info[ :peer_addr ].nil?
      src = @ctl_info[ :src ]
      return if src.nil? || src.closed?
      tun = Socket.new( Socket::AF_INET, Socket::SOCK_STREAM, 0 )
      tun.setsockopt( Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1 )
      tun.bind( @ctl.local_address )

      begin
        tun.connect_nonblock( @ctl_info[ :peer_addr ] )
      rescue IO::WaitWritable
      rescue Exception => e
        puts "#{ Time.new } connect peer addr #{ e.class }"
        tun.close
        close_ctl
        return nil
      end

      @tun_infos[ tun ] = {
        connected: false,
        wbuff: '',
        closing_write: false,
        paused: false,
        src: src
      }

      add_read( tun, :tun )
      add_write( tun )
      src_info = @src_infos[ src ]
      src_info[ :tun ] = tun
      src_info[ :punch_times ] += 1
      puts "#{ Time.new } #{ tun.local_address.inspect } connect #{ Addrinfo.new( @ctl_info[ :peer_addr ] ).inspect } tun infos #{ @tun_infos.size }"
      tun
    end

    ##
    # next tick
    #
    def next_tick
      @dotw.write( '.' )
    end

    ##
    # send title
    #
    def send_title
      begin
        @ctl.sendmsg( "#{ TO }#{ @title }", 0, @ctl_info[ :paird_addr ] )
      rescue Exception => e
        puts "#{ Time.new } ctl sendmsg #{ e.class }"
        close_ctl
      end
    end

    ##
    # set src closing write
    #
    def set_src_closing_write( src )
      return if src.nil? || src.closed?
      src_info = @src_infos[ src ]
      return if src_info[ :closing_write ]
      src_info[ :closing_write ] = true
      add_write( src )
    end

    ##
    # set tun closing write
    #
    def set_tun_closing_write( tun )
      return if tun.nil? || tun.closed?
      tun_info = @tun_infos[ tun ]
      return if tun_info[ :closing_write ]
      tun_info[ :closing_write ] = true
      add_write( tun )
    end

    ##
    # read dotr
    #
    def read_dotr( dotr )
      dotr.read_nonblock( READ_SIZE )

      @src_infos.select{ | _, info | info[ :closing ] }.keys.each do | src |
        src_info = close_src( src )

        if src_info then
          close_tun( src_info[ :tun ] )
        end
      end
    end

    ##
    # read shadow
    #
    def read_shadow( shadow )
      begin
        src, addrinfo = shadow.accept_nonblock
      rescue IO::WaitReadable, Errno::EINTR => e
        puts "accept #{ e.class }"
        return
      end

      @src_infos[ src ] = {
        rbuff: '',
        wbuff: '',
        closing_write: false,
        closing: false,
        paused: false,
        created_at: Time.new,
        last_recv_at: nil,
        last_sent_at: nil,
        tun: nil,
        punch_times: 0
      }

      puts "#{ Time.new } accept a src #{ addrinfo.inspect } src infos #{ @src_infos.size }"
      add_read( src, :src )
      close_ctl
      new_a_ctl( src )
    end

    ##
    # read src
    #
    def read_src( src )
      if src.closed? then
        puts "#{ Time.new } read src but src closed?"
        return
      end

      src_info = @src_infos[ src ]
      tun = src_info[ :tun ]

      begin
        data = src.read_nonblock( READ_SIZE )
      rescue Exception => e
        puts "#{ Time.new } read src #{ e.class }"
        close_read_src( src )
        set_tun_closing_write( tun )
        return
      end

      if tun && !tun.closed? && @tun_infos[ tun ][ :connected ] then
        add_tun_wbuff( tun, data )
      else
        puts "#{ Time.new } tun not connected, save data to src.rbuff #{ data.inspect }"
        add_src_rbuff( src, data )
      end
    end

    ##
    # read ctl
    #
    def read_ctl( ctl )
      if ctl.closed? then
        puts "#{ Time.new } read ctl but ctl closed?"
        return
      end

      data, addrinfo, rflags, *controls = ctl.recvmsg

      if @ctl_info[ :peer_addr ] then
        puts "#{ Time.new } peer addr already exist"
        return
      end

      if addrinfo.to_sockaddr != @ctl_info[ :paird_addr ] then
        puts "#{ Time.new } paird addr not match #{ addrinfo.inspect } #{ Addrinfo.new( @ctl_info[ :paird_addr ] ).inspect }"
        return
      end

      puts "#{ Time.new } read ctl #{ data.inspect }"
      @ctl_info[ :peer_addr ] = data
      new_a_tun
    end

    ##
    # read tun
    #
    def read_tun( tun )
      if tun.closed? then
        puts "#{ Time.new } read tun but tun closed?"
        return
      end

      tun_info = @tun_infos[ tun ]
      src = tun_info[ :src ]

      begin
        data = tun.read_nonblock( READ_SIZE )
      rescue Errno::ECONNREFUSED => e
        src_info = @src_infos[ src ]

        if src_info[ :punch_times ] >= PUNCH_LIMIT then
          puts "#{ Time.new } out of limit"
          close_tun( tun )
          close_src( src )
          return
        end

        puts "#{ Time.new } read tun #{ e.class } #{ src_info[ :punch_times ] }"
        close_tun( tun )

        unless new_a_tun then
          close_src( src )
        end

        return
      rescue Exception => e
        puts "#{ Time.new } read tun #{ e.class }"
        close_read_tun( tun )
        set_src_closing_write( src )
        return
      end

      add_src_wbuff( src, data )
    end

    ##
    # write tun
    #
    def write_tun( tun )
      if tun.closed? then
        puts "#{ Time.new } write tun but tun closed?"
        return
      end

      tun_info = @tun_infos[ tun ]
      src = tun_info[ :src ]
      src_info = @src_infos[ src ]

      unless tun_info[ :connected ] then
        puts "#{ Time.new } connected"
        tun_info[ :connected ] = true

        if src && !src.closed? then
          tun_info[ :wbuff ] << src_info[ :rbuff ]
        end
      end

      data = tun_info[ :wbuff ]

      # 写前为空，处理关闭写
      if data.empty? then
        if tun_info[ :closing_write ] then
          close_write_tun( tun )
        else
          @writes.delete( tun )
        end

        return
      end

      # 写入
      begin
        written = tun.write_nonblock( data )
      rescue Exception => e
        puts "#{ Time.new } write tun #{ e.class }"
        close_write_tun( tun )
        close_read_src( src )
        return
      end

      data = data[ written..-1 ]
      tun_info[ :wbuff ] = data

      if src && !src.closed? then
        src_info[ :last_sent_at ] = Time.new
      end
    end

    ##
    # write src
    #
    def write_src( src )
      if src.closed? then
        puts "#{ Time.new } write src but src closed?"
        return
      end

      src_info = @src_infos[ src ]
      data = src_info[ :wbuff ]

      # 写前为空，处理关闭写
      if data.empty? then
        if src_info[ :closing_write ] then
          close_write_src( src )
        else
          @writes.delete( src )
        end

        return
      end

      # 写入
      begin
        written = src.write_nonblock( data )
      rescue Exception => e
        puts "#{ Time.new } write src #{ e.class }"
        close_write_src( src )
        close_read_tun( src_info[ :tun ] )
        return
      end

      data = data[ written..-1 ]
      src_info[ :wbuff ] = data
    end
  end
end
