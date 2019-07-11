module P2p2
  PACK_SIZE = 1448 # 包大小
  CHUNK_SIZE = PACK_SIZE * 1000 # 块大小
  REP2P_LIMIT = 5 # p2p重试次数。到早了另一头还没从洞里出来，会吃ECONNREFUSED，不慌，再来一发。
  SET_TITLE = 1
  PAIRING = 2
  CTL_CLOSE_ROOM = [ 1 ].pack( 'C' )
  CTL_CLOSE_APP = [ 2 ].pack( 'C' )
end
