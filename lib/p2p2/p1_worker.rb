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
      @renew_times = 0

      new_a_pipe
      new_a_ctl
    end

    ##
    # looping
    #
    def looping
      puts "#{ Time.new } looping"
      loop_send_title
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
    def add_dst_rbuff( data )
      return if @dst.nil? || @dst.closed?
      @dst_info[ :rbuff ] << data

      if @dst_info[ :rbuff ].bytesize >= WBUFF_LIMIT then
        # puts "debug dst.rbuff full"
        close_dst
      end
    end

    ##
    # add dst wbuff
    #
    def add_dst_wbuff( data )
      return if @dst.nil? || @dst.closed?
      @dst_info[ :wbuff ] << data
      add_write( @dst )

      if ( @dst_info[ :wbuff ].bytesize >= WBUFF_LIMIT ) && @tun && !@tun.closed? then
        puts "#{ Time.new } pause tun"
        @reads.delete( @tun )
        @tun_info[ :paused ] = true
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
    def add_tun_wbuff( data )
      return if @tun.nil? || @tun.closed?
      @tun_info[ :wbuff ] << data
      add_write( @tun )

      if ( @tun_info[ :wbuff ].bytesize >= WBUFF_LIMIT ) && @dst && !@dst.closed? then
        puts "#{ Time.new } pause dst"
        @reads.delete( @dst )
        @dst_info[ :paused ] = true
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
    # clean dst info
    #
    def clean_dst_info
      @dst_info[ :rbuff ].clear
      @dst_info[ :wbuff ].clear
      @dst_info[ :closing_write ] = false
      @dst_info[ :paused ] = false
    end

    ##
    # clean tun info
    #
    def clean_tun_info
      @tun_info[ :connected ] = false
      @tun_info[ :wbuff ].clear
      @tun_info[ :closing_write ] = false
      @tun_info[ :paused ] = false
    end

    ##
    # close ctl
    #
    def close_ctl
      return if @ctl.nil? || @ctl.closed?
      puts "#{ Time.new } close ctl"
      close_sock( @ctl )
    end

    ##
    # close dst
    #
    def close_dst
      return if @dst.nil? || @dst.closed?
      puts "#{ Time.new } close dst"
      close_sock( @dst )
      clean_dst_info
    end

    ##
    # close read dst
    #
    def close_read_dst
      return if @dst.nil? || @dst.closed?
      # puts "debug close read dst"
      @dst.close_read
      @reads.delete( @dst )

      if @dst.closed? then
        # puts "debug dst closed"
        @writes.delete( @dst )
        @roles.delete( @dst )
        clean_dst_info
      end
    end

    ##
    # close read tun
    #
    def close_read_tun
      return if @tun.nil? || @tun.closed?
      # puts "debug close read tun"
      @tun.close_read
      @reads.delete( @tun )

      if @tun.closed? then
        # puts "debug tun closed"
        @writes.delete( @tun )
        @roles.delete( @tun )
        clean_tun_info
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
    def close_tun
      return if @tun.nil? || @tun.closed?
      puts "#{ Time.new } close tun"
      close_sock( @tun )
      clean_tun_info
    end

    ##
    # close write dst
    #
    def close_write_dst
      return if @dst.nil? || @dst.closed?
      # puts "debug close write dst"
      @dst.close_write
      @writes.delete( @dst )

      if @dst.closed? then
        # puts "debug dst closed"
        @reads.delete( @dst )
        @roles.delete( @dst )
        clean_dst_info
      end
    end

    ##
    # close write tun
    #
    def close_write_tun
      return if @tun.nil? || @tun.closed?
      # puts "debug close write tun"
      @tun.close_write
      @writes.delete( @tun )

      if @tun.closed? then
        # puts "debug tun closed"
        @reads.delete( @tun )
        @roles.delete( @tun )
        clean_tun_info
      end
    end

    ##
    # loop check state
    #
    def loop_check_state
      Thread.new do
        loop do
          sleep CHECK_STATE_INTERVAL

          if @dst && @dst_info[ :paused ] && @tun && ( @tun_info[ :wbuff ].size < RESUME_BELOW ) then
            puts "#{ Time.new } resume dst"
            add_read( @dst )
            @dst_info[ :paused ] = false
            next_tick
          end

          if @tun && @tun_info[ :paused ] && @dst && ( @dst_info[ :wbuff ].size < RESUME_BELOW ) then
            puts "#{ Time.new } resume tun"
            add_read( @tun )
            @tun_info[ :paused ] = false
            next_tick
          end
        end
      end
    end

    ##
    # loop send title
    #
    def loop_send_title
      Thread.new do
        loop do
          sleep SEND_TITLE_INTERVAL

          if @tun && !@tun.closed? then
            send_title
          else
            set_ctl_closing
          end
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
        return
      end

      @dst = dst
      @dst_info = {
        rbuff: '',
        wbuff: '',
        closing_write: false,
        paused: false
      }

      add_read( dst, :dst )
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
      tun = Socket.new( Socket::AF_INET, Socket::SOCK_STREAM, 0 )
      tun.setsockopt( Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1 )
      puts "#{ Time.new } bind ctl local address #{ @ctl.local_address.inspect } connect #{ Addrinfo.new( @ctl_info[ :peer_addr ] ).inspect }"
      tun.bind( @ctl.local_address )

      begin
        tun.connect_nonblock( @ctl_info[ :peer_addr ] )
      rescue IO::WaitWritable
      rescue Exception => e
        puts "#{ Time.new } tun connect ctl addr #{ e.class }"
        tun.close
        renew_ctl
        return
      end

      @tun = tun
      @tun_info = {
        connected: false,
        wbuff: '',
        closing_write: false,
        paused: false
      }

      add_read( tun, :tun )
      add_write( tun )
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
      # puts "debug renew ctl"
      close_ctl
      new_a_ctl
    end

    ##
    # renew dst
    #
    def renew_dst
      close_dst
      new_a_dst
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
    # renew tun
    #
    def renew_tun
      close_tun
      new_a_tun
    end

    ##
    # send title
    #
    def send_title
      # puts "debug send title #{ @title } #{ Addrinfo.new( @ctl_info[ :paird_addr ] ).inspect } #{ Time.new }"

      begin
        @ctl.sendmsg_nonblock( @title, 0, @ctl_info[ :paird_addr ] )
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
    def set_dst_closing_write
      return if @dst.nil? || @dst.closed? || @dst_info[ :closing_write ]
      @dst_info[ :closing_write ] = true
      add_write( @dst )
    end

    ##
    # set tun closing write
    #
    def set_tun_closing_write
      return if @tun.nil? || @tun.closed? || @tun_info[ :closing_write ]
      @tun_info[ :closing_write ] = true
      add_write( @tun )
    end

    ##
    # read dotr
    #
    def read_dotr( dotr )
      dotr.read_nonblock( READ_SIZE )

      if @ctl && !@ctl.closed? && @ctl_info[ :closing ] then
        renew_ctl
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
      renew_tun
      renew_dst
      @renew_times = 0
    end

    ##
    # read tun
    #
    def read_tun( tun )
      if tun.closed? then
        puts "#{ Time.new } read tun but tun closed?"
        return
      end

      begin
        data = tun.read_nonblock( READ_SIZE )
      rescue Errno::ECONNREFUSED => e
        if @renew_times >= RENEW_LIMIT then
          puts "#{ Time.new } out of limit"
          close_tun
          close_dst
          renew_ctl
          return
        end

        puts "#{ Time.new } read tun #{ e.class } #{ @renew_times }"
        renew_tun
        @renew_times += 1
        return
      rescue Exception => e
        puts "#{ Time.new } read tun #{ e.class }"
        close_read_tun
        set_dst_closing_write
        renew_paired_ctl
        return
      end

      add_dst_wbuff( data )
    end

    ##
    # read dst
    #
    def read_dst( dst )
      if dst.closed? then
        puts "#{ Time.new } read dst but dst closed?"
        return
      end

      begin
        data = dst.read_nonblock( READ_SIZE )
      rescue Exception => e
        puts "#{ Time.new } read dst #{ e.class }"
        close_read_dst
        set_tun_closing_write
        renew_paired_ctl
        return
      end

      if @tun && !@tun.closed? && @tun_info[ :connected ] then
        add_tun_wbuff( data )
      else
        # puts "debug tun not ready, save data to dst.rbuff #{ data.inspect }"
        add_dst_rbuff( data )
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

      unless @tun_info[ :connected ] then
        puts "#{ Time.new } connected"
        @tun_info[ :connected ] = true

        if @dst && !@dst.closed? && !@dst_info[ :rbuff ].empty? then
          # puts "debug move dst.rbuff to tun.wbuff"
          @tun_info[ :wbuff ] << @dst_info[ :rbuff ]
        end

        renew_ctl
      end

      data = @tun_info[ :wbuff ]

      # 写前为空，处理关闭写
      if data.empty? then
        if @tun_info[ :closing_write ] then
          close_write_tun
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
        close_write_tun
        close_read_dst
        renew_paired_ctl
        return
      end

      data = data[ written..-1 ]
      @tun_info[ :wbuff ] = data
    end

    ##
    # write dst
    #
    def write_dst( dst )
      if dst.closed? then
        puts "#{ Time.new } write dst but dst closed?"
        return
      end

      data = @dst_info[ :wbuff ]

      # 写前为空，处理关闭写
      if data.empty? then
        if @dst_info[ :closing_write ] then
          close_write_dst
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
        close_write_dst
        close_read_tun
        renew_paired_ctl
        return
      end

      data = data[ written..-1 ]
      @dst_info[ :wbuff ] = data
    end
  end
end
