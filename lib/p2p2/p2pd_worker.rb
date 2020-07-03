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

      from_addr = addrinfo.to_sockaddr
      room_path = File.join( @p2pd_tmp_dir, data.gsub( "\u0000" , '' ) )

      unless File.exist?( room_path )
        puts "#{ Time.new } create #{ room_path } #{ addrinfo.inspect }"
        write_room( room_path, from_addr )
        return
      end

      if Time.new - File.mtime( room_path ) > EXPIRE_AFTER
        puts "#{ Time.new } overwrite #{ room_path } #{ addrinfo.inspect }"
        write_room( room_path, from_addr )
        return
      end

      op_addr = IO.binread( room_path )
      op_addrinfo = Addrinfo.new( op_addr )

      if ( addrinfo.ip_address == op_addrinfo.ip_address ) || ( addrinfo.ip_port == op_addrinfo.ip_port )
        write_room( room_path, from_addr )
      else
        puts "#{ Time.new } paired #{ addrinfo.inspect } #{ op_addrinfo.inspect }"
        send_pack( [ [ 0, PEER_ADDR ].pack( 'Q>C' ), op_addr ].join, from_addr )
        send_pack( [ [ 0, PEER_ADDR ].pack( 'Q>C' ), from_addr ].join, op_addr )
      end
    end

    def write_room( room_path, data )
      begin
        IO.binwrite( room_path, data )
      rescue Errno::EISDIR, Errno::ENAMETOOLONG, Errno::ENOENT, ArgumentError => e
        puts "binwrite #{ e.class } #{ Time.new }"
      end
    end

    def send_pack( data, target_addr )
      begin
        @p2pd.sendmsg( data, 0, target_addr )
      rescue IO::WaitWritable, Errno::EINTR => e
        puts "#{ Time.new } sendmsg ignore #{ e.class }"
      end
    end
  end
end
