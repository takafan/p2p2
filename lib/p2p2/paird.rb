require 'json'
require 'p2p2/head'
require 'p2p2/paird_worker'
require 'p2p2/version'
require 'socket'

##
# P2p2::Paird - 配对服务。
#
module P2p2
  class Paird

    def initialize( config_path = nil )
      if config_path then
        conf = JSON.parse( IO.binread( config_path ), symbolize_names: true )
        paird_port = conf[ :paird_port ]
        infod_port = conf[ :infod_port ]
      end

      unless paird_port then
        paird_port = 4040
      end

      unless infod_port then
        infod_port = 4050
      end

      puts "p2p2 paird #{ P2p2::VERSION }"
      puts "paird #{ paird_port } infod #{ infod_port }"

      worker = P2p2::PairdWorker.new( paird_port, infod_port )

      Signal.trap( :TERM ) do
        puts 'exit'
        worker.quit!
      end

      worker.looping
    end

  end
end
