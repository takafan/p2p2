require 'json'
require 'p2p2/custom'
require 'p2p2/head'
require 'p2p2/p1_worker'
require 'p2p2/version'
require 'socket'

##
# P2p2::P1 - 内网里的任意应用，访问另一个内网里的应用服务端。p1端。
#
module P2p2
  class P1Worker

    def initialize( config_path = nil )
      unless config_path
        config_path = File.expand_path( '../p2p2.conf.json', __FILE__ )
      end

      unless File.exist?( config_path )
        raise "missing config file #{ config_path }"
      end

      conf = JSON.parse( IO.binread( config_path ), symbolize_names: true )
      p2pd_host = conf[ :p2pd_host ]
      p2pd_port = conf[ :p2pd_port ]
      room = conf[ :room ]
      appd_host = conf[ :appd_host ]
      appd_port = conf[ :appd_port ]
      p1_tmp_dir = conf[ :p1_tmp_dir ]

      unless p2pd_host
        raise "missing p2pd host"
      end

      unless room
        raise "missing room"
      end

      unless p2pd_port
        p2pd_port = 5050
      end

      unless appd_host
        appd_host = '127.0.0.1'
      end

      unless appd_port
        appd_port = 22
      end

      unless p1_tmp_dir
        p1_tmp_dir = '/tmp/p2p2.p1'
      end

      unless File.exist?( p1_tmp_dir )
        Dir.mkdir( p1_tmp_dir )
      end

      dst_chunk_dir = File.join( p1_tmp_dir, 'dst.chunk' )

      unless Dir.exist?( dst_chunk_dir )
        Dir.mkdir( dst_chunk_dir )
      end

      tund_chunk_dir = File.join( p1_tmp_dir, 'tund.chunk' )

      unless Dir.exist?( tund_chunk_dir )
        Dir.mkdir( tund_chunk_dir )
      end

      title = "p2p2 p1 #{ P2p2::VERSION }"
      puts title
      puts "p2pd host #{ p2pd_host }"
      puts "p2pd port #{ p2pd_port }"
      puts "room #{ room }"
      puts "appd host #{ appd_host }"
      puts "appd port #{ appd_port }"
      puts "p1 tmp dir #{ p1_tmp_dir }"
      puts "dst chunk dir #{ dst_chunk_dir }"
      puts "tund chunk dir #{ tund_chunk_dir }"

      if RUBY_PLATFORM.include?( 'linux' )
        $0 = title

        pid = fork do
          $0 = 'p2p2 p1 worker'
          worker = P2p2::P1Worker.new( p2pd_host, p2pd_port, room, appd_host, appd_port, dst_chunk_dir, tund_chunk_dir )

          Signal.trap( :TERM ) do
            puts "w#{ i } exit"
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
        P2p2::P1Worker.new( p2pd_host, p2pd_port, room, appd_host, appd_port, dst_chunk_dir, tund_chunk_dir ).looping
      end
    end

  end
end
