require 'json'
require 'p2p2/concurrent_hash'
require 'p2p2/head'
require 'p2p2/p2_worker'
require 'p2p2/version'
require 'socket'

##
# P2p2::P2 - p2端
#
module P2p2
  class P2

    def initialize( config_path = nil )
      unless config_path then
        config_path = File.expand_path( '../p2p2.conf.json', __FILE__ )
      end

      raise "missing config file #{ config_path }" unless File.exist?( config_path )

      conf = JSON.parse( IO.binread( config_path ), symbolize_names: true )
      paird_host = conf[ :paird_host ]
      paird_port = conf[ :paird_port ]
      room = conf[ :room ]
      shadow_host = conf[ :shadow_host ]
      shadow_port = conf[ :shadow_port ]

      raise 'missing paird host' unless paird_host
      raise 'missing room' unless room

      unless paird_port then
        paird_port = 4040
      end

      unless shadow_host then
        shadow_host = '0.0.0.0'
      end

      unless shadow_port then
        shadow_port = 4444
      end

      puts "p2p2 p2 #{ P2p2::VERSION }"
      puts "paird #{ paird_host } #{ paird_port } room #{ room } shadow #{ shadow_host } #{ shadow_port }"

      worker = P2p2::P2Worker.new( paird_host, paird_port, room, shadow_host, shadow_port )

      Signal.trap( :TERM ) do
        puts 'exit'
        worker.quit!
      end

      worker.looping
    end

  end
end
