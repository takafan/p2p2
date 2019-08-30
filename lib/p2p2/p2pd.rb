require 'p2p2/head'
require 'p2p2/version'
require 'socket'

##
# P2p2::P2pd - 内网里的任意应用，访问另一个内网里的应用服务端。配对服务器端。
#
# 1.
#
# ```
#                    p2pd
#                    ^  ^
#                  ^    ^
#      “周立波的房间”     “周立波的房间”
#      ^                         ^
#     ^                         ^
#   p1 --> nat --><-- nat <-- p2
#
# ```
#
# 2.
#
# ```
#   ssh --> p2 --> (encode) --> p1 --> (decode) --> sshd
# ```
#
# usage
# =====
#
# 1. Girl::P2pd.new( 5050 ).looping # @server
#
# 2. Girl::P1.new( 'your.server.ip', 5050, '127.0.0.1', 22, '周立波' ).looping # @home1
#
# 3. Girl::P2.new( 'your.server.ip', 5050, '0.0.0.0', 2222, '周立波' ).looping # @home2
#
# 4. ssh -p2222 libo@localhost
#
# 包结构
# ======
#
# Q>: 1+ app/shadow_id -> Q>: pack_id  -> traffic
#     0  ctlmsg        -> C:  1 peer addr     -> p1/p2_sockaddr
#                             2 heartbeat     -> C: random char
#                             3 a new app     -> Q>: app_id
#                             4 paired        -> Q>Q>: app_id shadow_id
#                             5 shadow status -> Q>Q>Q>: shadow_id biggest_shadow_pack_id continue_app_pack_id
#                             6 app status    -> Q>Q>Q>: app_id biggest_app_pack_id continue_shadow_pack_id
#                             7 miss          -> Q>Q>Q>: app/shadow_id pack_id_begin pack_id_end
#                             8 fin1          -> Q>: app/shadow_id
#                             9 got fin1      -> Q>: app/shadow_id
#                            10 fin2          -> Q>: app/shadow_id
#                            11 got fin2      -> Q>: app/shadow_id
#                            12 p1 fin
#                            13 p2 fin
#
module P2p2
  class P2pd

    ##
    # p2pd_port 配对服务器端口
    # p2pd_dir  可在该目录下看到所有的房间
    def initialize( p2pd_port = 5050, p2pd_dir = '/tmp' )
      p2pd = Socket.new( Socket::AF_INET, Socket::SOCK_DGRAM, 0 )
      p2pd.setsockopt( Socket::SOL_SOCKET, Socket::SO_REUSEADDR, 1 )
      p2pd.bind( Socket.pack_sockaddr_in( p2pd_port, '0.0.0.0' ) )

      @p2pd = p2pd
      @p2pd_dir = p2pd_dir
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
      return if ( data.bytesize > 255 ) || ( data =~ /\/|\.|\ / )

      sockaddr = addrinfo.to_sockaddr
      title_path = File.join( @p2pd_dir, data )

      unless File.exist?( title_path )
        write_title( title_path, sockaddr )
        send_heartbeat( p2pd, sockaddr )
        return
      end

      if Time.new - File.mtime( title_path ) > 300
        write_title( title_path, sockaddr )
        send_heartbeat( p2pd, sockaddr )
        return
      end

      op_sockaddr = IO.binread( title_path )

      if Addrinfo.new( op_sockaddr ).ip_address == addrinfo.ip_address
        write_title( title_path, sockaddr )
        send_heartbeat( p2pd, sockaddr )
        return
      end

      send_pack( p2pd, "#{ [ 0, PEER_ADDR ].pack( 'Q>C' ) }#{ op_sockaddr }", sockaddr )
      send_pack( p2pd, "#{ [ 0, PEER_ADDR ].pack( 'Q>C' ) }#{ sockaddr }", op_sockaddr )
    end

    def write_title( title_path, sockaddr )
      begin
        # puts "debug write title #{ title_path } #{ Time.new }"
        IO.binwrite( title_path, sockaddr )
      rescue Errno::EISDIR, Errno::ENAMETOOLONG, Errno::ENOENT, ArgumentError => e
        puts "binwrite #{ e.class } #{ Time.new }"
      end
    end

    def send_heartbeat( p2pd, target_addr )
      ctlmsg = [ 0, HEARTBEAT, rand( 128 ) ].pack( 'Q>CC' )
      send_pack( p2pd, ctlmsg, target_addr )
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
