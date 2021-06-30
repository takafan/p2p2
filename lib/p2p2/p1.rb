require 'json'
require 'p2p2/head'
require 'p2p2/p1_worker'
require 'p2p2/version'
require 'socket'

##
# P2p2::P1 - p1端
#
# send title Exception:               renew ctl
# loop send title:                    renew ctl if tun closed
# read ctl peer addr:                 renew tun, renew dst
# read tun ECONNREFUSED out of limit: close tun, close dst, renew ctl
# read tun ECONNREFUSED:              renew tun
# read tun other Exception:           close read tun, set dst closing write, renew paired ctl
# read dst Exception:                 close read dst, set tun closing write, renew paired ctl
# write tun:                          renew ctl if once connected
# write tun Exception:                close write tun, close read dst, renew paired ctl
# write dst Exception:                close write dst, close read tun, renew paired ctl
#
module P2p2
  class P1

    def initialize( config_path = nil )
      unless config_path then
        config_path = File.expand_path( '../p2p2.conf.json', __FILE__ )
      end

      raise "missing config file #{ config_path }" unless File.exist?( config_path )

      conf = JSON.parse( IO.binread( config_path ), symbolize_names: true )
      paird_host = conf[ :paird_host ]
      paird_port = conf[ :paird_port ]
      room = conf[ :room ]
      appd_host = conf[ :appd_host ]
      appd_port = conf[ :appd_port ]

      raise 'missing paird host' unless paird_host
      raise 'missing room' unless room

      unless paird_port then
        paird_port = 4040
      end

      unless appd_host then
        appd_host = '127.0.0.1'
      end

      unless appd_port then
        appd_port = 22
      end

      puts "p2p2 p1 #{ P2p2::VERSION }"
      puts "paird #{ paird_host } #{ paird_port } room #{ room } appd #{ appd_host } #{ appd_port }"

      worker = P2p2::P1Worker.new( paird_host, paird_port, room, appd_host, appd_port )

      Signal.trap( :TERM ) do
        puts 'exit'
        worker.quit!
      end

      worker.looping
    end

  end
end
