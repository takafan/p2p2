module P2p2
  class PairdWorker

    ##
    # initialize
    #
    def initialize( paird_port, infod_port )
      @reads = []
      @roles = {}      # :paird / :infod
      @room_infos = {} # title => { p1_paird, p1_addrinfo, p2_paird, p2_addrinfo, updated_at }
      new_pairds( paird_port )
      new_a_infod( infod_port )
    end

    ##
    # looping
    #
    def looping
      puts "#{ Time.new } looping"

      loop do
        rs, _ = IO.select( @reads )

        rs.each do | sock |
          role = @roles[ sock ]

          case role
          when :paird
            read_paird( sock )
          when :infod
            read_infod( sock )
          else
            puts "#{ Time.new } read unknown role #{ role }"
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
    # new a infod
    #
    def new_a_infod( infod_port )
      infod = Socket.new( Socket::AF_INET, Socket::SOCK_DGRAM, 0 )
      infod.setsockopt( Socket::SOL_SOCKET, Socket::SO_REUSEPORT, 1 )
      infod.bind( Socket.sockaddr_in( infod_port, '127.0.0.1' ) )

      puts "#{ Time.new } infod bind on #{ infod_port }"
      add_read( infod, :infod )
    end

    ##
    # new pairds
    #
    def new_pairds( begin_port )
      10.times do | i |
        paird_port = begin_port + i
        paird = Socket.new( Socket::AF_INET, Socket::SOCK_DGRAM, 0 )
        paird.setsockopt( Socket::SOL_SOCKET, Socket::SO_REUSEPORT, 1 )
        paird.bind( Socket.sockaddr_in( paird_port, '0.0.0.0' ) )
        puts "#{ Time.new } paird bind on #{ paird_port }"
        add_read( paird, :paird )
      end
    end

    ##
    # send data
    #
    def send_data( sock, data, target_addr )
      begin
        sock.sendmsg_nonblock( data, 0, target_addr )
      rescue Exception => e
        puts "#{ Time.new } sendmsg #{ e.class }"
      end
    end

    ##
    # read paird
    #
    def read_paird( paird )
      data, addrinfo, rflags, *controls = paird.recvmsg
      return if data =~ /\r|\n/

      is_p2 = ( data[ 0 ] == TO )
      title = is_p2 ? data[ 1..-1 ] : data
      return if title.empty? || ( title.size > ROOM_TITLE_LIMIT )

      room_info = @room_infos[ title ]

      unless is_p2 then
        if room_info then
          room_info[ :p1_paird ] = paird
          room_info[ :p1_addrinfo ] = addrinfo
          room_info[ :updated_at ] = Time.new
        else
          @room_infos[ title ] = {
            p1_paird: paird,
            p1_addrinfo: addrinfo,
            p2_paird: nil,
            p2_addrinfo: nil,
            updated_at: Time.new
          }
        end

        return
      end

      return unless room_info

      room_info[ :p2_paird ] = paird
      room_info[ :p2_addrinfo ] = addrinfo

      puts "#{ Time.new } paired #{ room_info[ :p1_addrinfo ].inspect } #{ room_info[ :p2_addrinfo ].inspect }"
      send_data( room_info[ :p1_paird ], room_info[ :p2_addrinfo ].to_sockaddr, room_info[ :p1_addrinfo ] )
      send_data( room_info[ :p2_paird ], room_info[ :p1_addrinfo ].to_sockaddr, room_info[ :p2_addrinfo ] )
    end

    ##
    # read infod
    #
    def read_infod( infod )
      data, addrinfo, rflags, *controls = infod.recvmsg

      data2 = @room_infos.sort_by{ | _, info | info[ :updated_at ] }.reverse.map do | title, info |
        [
          info[ :updated_at ],
          title + ' ' * ( ROOM_TITLE_LIMIT - title.size ),
          info[ :p1_addrinfo ].ip_unpack.join( ':' )
        ].join( ' ' )
      end.join( "\n" )

      send_data( infod, data2, addrinfo )
    end
  end
end
