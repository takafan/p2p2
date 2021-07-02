module P2p2
  class P1Worker

    ##
    # initialize
    #
    def initialize( paird_host, paird_port, title, appd_host, appd_port )
      @paird_host = paird_host
      @paird_port = paird_port
      @title = title
      @appd_addr = Socket.sockaddr_in( appd_port, appd_host )
      @reads = []
      @writes = []
      @roles = {} # sock => :dotr / :ctl / :tun / :dst
      @dst_infos = ConcurrentHash.new
      @tun_infos = ConcurrentHash.new

      new_a_pipe
      new_a_ctl
    end

    ##
    # looping
    #
    def looping
      puts "#{ Time.new } looping"
      loop_renew_ctl
      loop_check_state

      loop do
        rs, ws = IO.select( @reads, @writes )

        rs.each do | sock |
          role = @roles[ sock ]

          case role
          when :dotr then
            read_dotr( sock )
          when :ctl then
            read_ctl( sock )
          when :tun then
            read_tun( sock )
          when :dst then
            read_dst( sock )
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
          when :dst then
            write_dst( sock )
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
    # add dst rbuff
    #
    def add_dst_rbuff( dst, data )
      return if dst.nil? || dst.closed?
      dst_info = @dst_infos[ dst ]
      dst_info[ :rbuff ] << data

      if dst_info[ :rbuff ].bytesize >= WBUFF_LIMIT then
        puts "#{ Time.new } dst.rbuff full"
        close_dst( dst )
      end
    end

    ##
    # add dst wbuff
    #
    def add_dst_wbuff( dst, data )
      return if dst.nil? || dst.closed?
      dst_info = @dst_infos[ dst ]
      dst_info[ :wbuff ] << data
      dst_info[ :last_recv_at ] = Time.new
      add_write( dst )

      if dst_info[ :wbuff ].bytesize >= WBUFF_LIMIT then
        tun = dst_info[ :tun ]

        if tun && !tun.closed? then
          puts "#{ Time.new } pause tun"
          @reads.delete( tun )
          tun_info = @tun_infos[ tun ]
          tun_info[ :paused ] = true
        end
      end
    end

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
    # add tun wbuff
    #
    def add_tun_wbuff( tun, data )
      return if tun.nil? || tun.closed?
      tun_info = @tun_infos[ tun ]
      tun_info[ :wbuff ] << data
      add_write( tun )

      if tun_info[ :wbuff ].bytesize >= WBUFF_LIMIT then
        dst = tun_info[ :dst ]

        if dst && !dst.closed? then
          puts "#{ Time.new } pause dst"
          @reads.delete( dst )
          dst_info = @dst_infos[ dst ]
          dst_info[ :paused ] = true
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
    # close dst
    #
    def close_dst( dst )
      return if dst.nil? || dst.closed?
      puts "#{ Time.new } close dst"
      close_sock( dst )
      @dst_infos.delete( dst )
    end

    ##
    # close read dst
    #
    def close_read_dst( dst )
      return if dst.nil? || dst.closed?
      # puts "debug close read dst"
      dst.close_read
      @reads.delete( dst )

      if dst.closed? then
        # puts "debug dst closed"
        @writes.delete( dst )
        @roles.delete( dst )
        @dst_infos.delete( dst )
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
    # close tun
    #
    def close_tun( tun )
      return if tun.nil? || tun.closed?
      puts "#{ Time.new } close tun"
      close_sock( tun )
      @tun_infos.delete( tun )
    end

    ##
    # close write dst
    #
    def close_write_dst( dst )
      return if dst.nil? || dst.closed?
      # puts "debug close write dst"
      dst.close_write
      @writes.delete( dst )

      if dst.closed? then
        # puts "debug dst closed"
        @reads.delete( dst )
        @roles.delete( dst )
        @dst_infos.delete( dst )
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

          @dst_infos.select{ | dst, _ | !dst.closed? }.each do | dst, dst_info |
            last_recv_at = dst_info[ :last_recv_at ] || dst_info[ :created_at ]
            last_sent_at = dst_info[ :last_sent_at ] || dst_info[ :created_at ]
            is_expire = ( now - last_recv_at >= EXPIRE_AFTER ) && ( now - last_sent_at >= EXPIRE_AFTER )

            if is_expire then
              puts "#{ Time.new } expire dst"
              dst_info[ :closing ] = true
              next_tick
            elsif dst_info[ :paused ] then
              tun = dst_info[ :tun ]

              if tun && !tun.closed? then
                tun_info = @tun_infos[ tun ]

                if tun_info[ :wbuff ].bytesize < RESUME_BELOW then
                  puts "#{ Time.new } resume dst"
                  add_read( dst )
                  dst_info[ :paused ] = false
                  next_tick
                end
              end
            end
          end

          @tun_infos.select{ | tun, info | !tun.closed? && info[ :paused ] }.each do | tun, tun_info |
            dst = tun_info[ :dst ]

            if dst && !dst.closed? then
              dst_info = @dst_infos[ dst ]

              if dst_info[ :wbuff ].bytesize < RESUME_BELOW then
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
    # loop renew ctl
    #
    def loop_renew_ctl
      Thread.new do
        loop do
          sleep RENEW_CTL_INTERVAL
          set_ctl_closing
        end
      end
    end

    ##
    # new a ctl
    #
    def new_a_ctl
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
        dst: nil,
        closing: false
      }

      add_read( ctl, :ctl )

      puts "#{ Time.new } hello i'm #{ @title.inspect } #{ Addrinfo.new( @ctl_info[ :paird_addr ] ).inspect }"
      send_title
    end

    ##
    # new a dst
    #
    def new_a_dst
      dst = Socket.new( Socket::AF_INET, Socket::SOCK_STREAM, 0 )
      dst.setsockopt( Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1 )

      begin
        dst.connect_nonblock( @appd_addr )
      rescue IO::WaitWritable
      rescue Exception => e
        puts "#{ Time.new } dst connect appd addr #{ e.class }"
        dst.close
        renew_ctl
        return nil
      end

      @dst_infos[ dst ] = {
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

      puts "#{ Time.new } dst infos #{ @dst_infos.size }"
      add_read( dst, :dst )
      dst
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
    # new a tun
    #
    def new_a_tun
      return if @ctl.nil? || @ctl.closed? || @ctl_info[ :peer_addr ].nil?
      dst = @ctl_info[ :dst ]
      return if dst.nil? || dst.closed?
      tun = Socket.new( Socket::AF_INET, Socket::SOCK_STREAM, 0 )
      tun.setsockopt( Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1 )
      tun.bind( @ctl.local_address )

      begin
        tun.connect_nonblock( @ctl_info[ :peer_addr ] )
      rescue IO::WaitWritable
      rescue Exception => e
        puts "#{ Time.new } connect peer addr #{ e.class }"
        tun.close
        renew_ctl
        return nil
      end

      @tun_infos[ tun ] = {
        connected: false,
        wbuff: '',
        closing_write: false,
        paused: false,
        dst: dst
      }

      add_read( tun, :tun )
      add_write( tun )
      dst_info = @dst_infos[ dst ]
      dst_info[ :tun ] = tun
      dst_info[ :punch_times ] += 1
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
    # renew ctl
    #
    def renew_ctl
      puts "#{ Time.new } renew ctl"
      close_ctl
      new_a_ctl
    end

    ##
    # renew paired ctl
    #
    def renew_paired_ctl
      if @ctl && !@ctl.closed? && @ctl_info[ :peer_addr ] then
        puts "#{ Time.new } renew paired ctl"
        renew_ctl
      end
    end

    ##
    # send title
    #
    def send_title
      begin
        @ctl.sendmsg( @title, 0, @ctl_info[ :paird_addr ] )
      rescue Exception => e
        puts "#{ Time.new } ctl sendmsg #{ e.class }"
        set_ctl_closing
      end
    end

    ##
    # set ctl closing
    #
    def set_ctl_closing
      return if @ctl.nil? || @ctl.closed? || @ctl_info[ :closing ]
      @ctl_info[ :closing ] = true
      next_tick
    end

    ##
    # set dst closing write
    #
    def set_dst_closing_write( dst )
      return if dst.nil? || dst.closed?
      dst_info = @dst_infos[ dst ]
      return if dst_info[ :closing_write ]
      dst_info[ :closing_write ] = true
      add_write( dst )
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

      if @ctl && !@ctl.closed? && @ctl_info[ :closing ] then
        renew_ctl
      end

      @dst_infos.select{ | _, info | info[ :closing ] }.keys.each do | dst |
        dst_info = close_dst( dst )

        if dst_info then
          close_tun( dst_info[ :tun ] )
        end
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
      @ctl_info[ :dst ] = new_a_dst
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
      dst = tun_info[ :dst ]

      if dst.nil? || dst.closed? then
        puts "#{ Time.new } read tun but dst already closed"
        close_tun( tun )
        return
      end

      begin
        data = tun.read_nonblock( READ_SIZE )
      rescue Errno::ECONNREFUSED => e
        dst_info = @dst_infos[ dst ]

        if dst_info[ :punch_times ] >= PUNCH_LIMIT then
          puts "#{ Time.new } out of limit"
          close_tun( tun )
          close_dst( dst )
          renew_ctl
          return
        end

        puts "#{ Time.new } read tun #{ e.class } #{ dst_info[ :punch_times ] }"
        close_tun( tun )

        unless new_a_tun then
          close_dst( dst )
          renew_ctl
        end

        return
      rescue Exception => e
        puts "#{ Time.new } read tun #{ e.class }"
        close_read_tun( tun )
        set_dst_closing_write( dst )
        renew_paired_ctl
        return
      end

      add_dst_wbuff( dst, data )
    end

    ##
    # read dst
    #
    def read_dst( dst )
      if dst.closed? then
        puts "#{ Time.new } read dst but dst closed?"
        return
      end

      dst_info = @dst_infos[ dst ]
      tun = dst_info[ :tun ]

      begin
        data = dst.read_nonblock( READ_SIZE )
      rescue Exception => e
        puts "#{ Time.new } read dst #{ e.class }"
        close_read_dst( dst )
        set_tun_closing_write( tun )
        renew_paired_ctl
        return
      end

      if tun && !tun.closed? && @tun_infos[ tun ][ :connected ] then
        add_tun_wbuff( tun, data )
      else
        puts "#{ Time.new } tun not connected, save data to dst.rbuff #{ data.inspect }"
        add_dst_rbuff( dst, data )
      end
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
      dst = tun_info[ :dst ]
      dst_info = @dst_infos[ dst ]

      unless tun_info[ :connected ] then
        puts "#{ Time.new } connected"
        tun_info[ :connected ] = true

        if dst && !dst.closed? then
          tun_info[ :wbuff ] << dst_info[ :rbuff ]
        end

        renew_ctl
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
        close_read_dst( dst )
        renew_paired_ctl
        return
      end

      data = data[ written..-1 ]
      tun_info[ :wbuff ] = data

      if dst && !dst.closed? then
        dst_info[ :last_sent_at ] = Time.new
      end
    end

    ##
    # write dst
    #
    def write_dst( dst )
      if dst.closed? then
        puts "#{ Time.new } write dst but dst closed?"
        return
      end

      dst_info = @dst_infos[ dst ]
      data = dst_info[ :wbuff ]

      # 写前为空，处理关闭写
      if data.empty? then
        if dst_info[ :closing_write ] then
          close_write_dst( dst )
        else
          @writes.delete( dst )
        end

        return
      end

      # 写入
      begin
        written = dst.write_nonblock( data )
      rescue Exception => e
        puts "#{ Time.new } write dst #{ e.class }"
        close_write_dst( dst )
        close_read_tun( dst_info[ :tun ] )
        renew_paired_ctl
        return
      end

      data = data[ written..-1 ]
      dst_info[ :wbuff ] = data
    end
  end
end
