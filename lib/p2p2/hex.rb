module P2p2
  class Hex
    def gen_random_num
      rand( ( 2 ** 64 ) - 1 ) + 1
    end
    
    def encode( data )
      data
    end

    def decode( data )
      data
    end
  end
end
