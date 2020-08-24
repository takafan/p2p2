require 'json'
require 'p2p2/head'
require 'p2p2/p2pd_worker'
require 'p2p2/version'
require 'socket'

##
# P2p2::P2pd - 配对服务。
#
# 包结构
# ======
#
# tund-p2pd, tun-p2pd:
#
# room
#
# p2pd-tund, p2pd-tun:
#
# Q>: 0  ctlmsg -> C:  1 peer addr -> tun sockaddr / tund sockaddr
#
# tun-tund:
#
# Q>: 0  ctlmsg -> C: 2 heartbeat     -> C: random char
#                     3 a new source  -> Q>: src id
#                     4 paired        -> Q>: src id -> n: dst port
#                     5 dest status   -> n: dst port -> Q>: biggest relayed dst pack id -> Q>: continue src pack id
#                     6 source status -> Q>: src id -> Q>: biggest relayed src pack id -> Q>: continue dst pack id
#                     7 miss          -> Q>/n: src id / dst port -> Q>: pack id begin -> Q>: pack id end
#                     8 fin1          -> Q>/n: src id / dst port -> Q>: biggest src pack id / biggest dst pack id -> Q>: continue dst pack id / continue src pack id
#                     9 not use
#                    10 fin2          -> Q>/n: src id / dst port
#                    11 not use
#                    12 tund fin
#                    13 tun fin
#
# Q>: 1+ pack_id -> Q>/n: src id / dst port -> traffic
#
# close logic
# ===========
#
# 1-1. after close src -> dst closed ? no -> send fin1
# 1-2. tun recv fin2 -> del src ext
#
# 2-1. tun recv fin1 -> all traffic received ? -> close src after write
# 2-2. tun recv traffic -> dst closed and all traffic received ? -> close src after write
# 2-3. after close src -> dst closed ? yes -> del src ext -> send fin2
#
# 3-1. after close dst -> src closed ? no -> send fin1
# 3-2. tund recv fin2 -> del dst ext
#
# 4-1. tund recv fin1 -> all traffic received ? -> close dst after write
# 4-2. tund recv traffic -> src closed and all traffic received ? -> close dst after write
# 4-3. after close dst -> src closed ? yes -> del dst ext -> send fin2
#
module P2p2
  class P2pd

    def initialize( config_path = nil )
      unless config_path
        config_path = File.expand_path( '../p2p2.conf.json', __FILE__ )
      end

      unless File.exist?( config_path )
        raise "missing config file #{ config_path }"
      end

      conf = JSON.parse( IO.binread( config_path ), symbolize_names: true )
      p2pd_port = conf[ :p2pd_port ]
      p2pd_tmp_dir = conf[ :p2pd_tmp_dir ]

      unless p2pd_port
        p2pd_port = 2020
      end

      unless p2pd_tmp_dir
        p2pd_tmp_dir = '/tmp/p2p2.p2pd'
      end

      unless File.exist?( p2pd_tmp_dir )
        Dir.mkdir( p2pd_tmp_dir )
      end

      title = "p2p2 p2pd #{ P2p2::VERSION }"
      puts title
      puts "p2pd port #{ p2pd_port }"
      puts "p2pd tmp dir #{ p2pd_tmp_dir }"

      if RUBY_PLATFORM.include?( 'linux' )
        $0 = title

        pid = fork do
          $0 = 'p2p2 p2pd worker'
          worker = P2p2::P2pdWorker.new( p2pd_port, p2pd_tmp_dir )

          Signal.trap( :TERM ) do
            puts 'exit'
            worker.quit!
          end

          worker.looping
        end

        Signal.trap( :TERM ) do
          puts 'trap TERM'

          begin
            Process.kill( :TERM, pid )
          rescue Errno::ESRCH => e
            puts e.class
          end
        end

        Process.waitall
      else
        P2p2::P2pdWorker.new( p2pd_port, p2pd_tmp_dir ).looping
      end
    end

  end
end
