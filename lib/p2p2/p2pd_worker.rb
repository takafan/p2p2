module P2p2
  class P2pdWorker

    def initialize( p2pd_port, p2pd_tmp_dir )
      p2pd = Socket.new( Socket::AF_INET, Socket::SOCK_DGRAM, 0 )
      p2pd.setsockopt( Socket::SOL_SOCKET, Socket::SO_REUSEADDR, 1 )
      p2pd.bind( Socket.pack_sockaddr_in( p2pd_port, '0.0.0.0' ) )

      @p2pd = p2pd
      @p2pd_tmp_dir = p2pd_tmp_dir
    end

    def looping
      puts 'looping'

      loop do
        rs, _ = IO.select( [ @p2pd ] )
        read_p2pd( rs.first )
      end
    rescue Interrupt => e
      puts e.class
      quit!
    end

    def quit!
      exit
    end

    private

    def read_p2pd( p2pd )
      data, addrinfo, rflags, *controls = p2pd.recvmsg
      return if ( data.bytesize == 1 ) || ( data.bytesize > 255 ) || ( data =~ /\/|\.|\ / )

      sockaddr = addrinfo.to_sockaddr
      room_path = File.join( @p2pd_tmp_dir, data.gsub( "\u0000" , '' ) )

      unless File.exist?( room_path )
        write_room( room_path, sockaddr )
        return
      end

      if Time.new - File.mtime( room_path ) > EXPIRE_AFTER
        write_room( room_path, sockaddr )
        return
      end

      op_sockaddr = IO.binread( room_path )

      if Addrinfo.new( op_sockaddr ).ip_address == addrinfo.ip_address
        write_room( room_path, sockaddr )
        return
      end

      send_pack( p2pd, "#{ [ 0, PEER_ADDR ].pack( 'Q>C' ) }#{ op_sockaddr }", sockaddr )
      send_pack( p2pd, "#{ [ 0, PEER_ADDR ].pack( 'Q>C' ) }#{ sockaddr }", op_sockaddr )
    end

    def write_room( room_path, sockaddr )
      begin
        # puts "debug write room #{ room_path } #{ Time.new }"
        IO.binwrite( room_path, sockaddr )
      rescue Errno::EISDIR, Errno::ENAMETOOLONG, Errno::ENOENT, ArgumentError => e
        puts "binwrite #{ e.class } #{ Time.new }"
      end
    end

    def send_pack( sock, data, target_sockaddr )
      begin
        # puts "debug sendmsg #{ data.inspect } #{ Time.new }"
        sock.sendmsg( data, 0, target_sockaddr )
      rescue IO::WaitWritable, Errno::EINTR => e
        puts "sendmsg #{ e.class } #{ Time.new }"
      end
    end
  end
end
