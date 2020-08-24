require 'json'
require 'p2p2/head'
require 'p2p2/p2_custom'
require 'p2p2/p2_worker'
require 'p2p2/version'
require 'socket'

##
# P2p2::P2 - p2p通道，p2端。
#
module P2p2
  class P2

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
      sdwd_host = conf[ :sdwd_host ]
      sdwd_port = conf[ :sdwd_port ]
      p2_tmp_dir = conf[ :p2_tmp_dir ]

      unless p2pd_host
        raise "missing p2pd host"
      end

      unless room
        raise "missing room"
      end

      unless p2pd_port
        p2pd_port = 2020
      end

      unless sdwd_host
        sdwd_host = '0.0.0.0'
      end

      unless sdwd_port
        sdwd_port = 2222
      end

      unless p2_tmp_dir
        p2_tmp_dir = '/tmp/p2p2.p2'
      end

      unless File.exist?( p2_tmp_dir )
        Dir.mkdir( p2_tmp_dir )
      end

      src_chunk_dir = File.join( p2_tmp_dir, 'src.chunk' )

      unless Dir.exist?( src_chunk_dir )
        Dir.mkdir( src_chunk_dir )
      end

      tun_chunk_dir = File.join( p2_tmp_dir, 'tun.chunk' )

      unless Dir.exist?( tun_chunk_dir )
        Dir.mkdir( tun_chunk_dir )
      end

      title = "p2p2 p2 #{ P2p2::VERSION }"
      puts title
      puts "p2pd host #{ p2pd_host }"
      puts "p2pd port #{ p2pd_port }"
      puts "room #{ room }"
      puts "sdwd host #{ sdwd_host }"
      puts "sdwd port #{ sdwd_port }"
      puts "p2 tmp dir #{ p2_tmp_dir }"
      puts "src chunk dir #{ src_chunk_dir }"
      puts "tun chunk dir #{ tun_chunk_dir }"

      if RUBY_PLATFORM.include?( 'linux' )
        $0 = title

        pid = fork do
          $0 = 'p2p2 p2 worker'
          worker = P2p2::P2Worker.new( p2pd_host, p2pd_port, room, sdwd_host, sdwd_port, src_chunk_dir, tun_chunk_dir )

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
        P2p2::P2Worker.new( p2pd_host, p2pd_port, room, sdwd_host, sdwd_port, src_chunk_dir, tun_chunk_dir ).looping
      end
    end

  end
end
