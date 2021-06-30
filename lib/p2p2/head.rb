module P2p2
  READ_SIZE             = 1024 * 1024      # 一次读多少
  WBUFF_LIMIT           = 50 * 1024 * 1024 # 写前上限，超过上限暂停读
  RESUME_BELOW          = WBUFF_LIMIT / 2  # 降到多少以下恢复读
  SEND_TITLE_INTERVAL   = 60               # p1心跳间隔
  CHECK_STATE_INTERVAL  = 1                # 检查过期，恢复读
  ROOM_TITLE_LIMIT      = 16               # 房间名称字数
  RENEW_LIMIT           = 5                # p2p重试次数
  TO                    = ':'              # 找房间前缀
end
