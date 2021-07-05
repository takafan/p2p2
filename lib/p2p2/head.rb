module P2p2
  READ_SIZE             = 1024 * 1024      # 一次读多少
  WBUFF_LIMIT           = 50 * 1024 * 1024 # 写前上限，超过上限暂停读
  RESUME_BELOW          = WBUFF_LIMIT / 2  # 降到多少以下恢复读
  RENEW_CTL_INTERVAL    = 10               # p1心跳间隔，部分光猫udp端口映射过期时间只有10秒
  CHECK_STATE_INTERVAL  = 1                # 检查过期，恢复读间隔
  EXPIRE_AFTER          = 86400            # 多久没有新流量，过期
  ROOM_TITLE_LIMIT      = 16               # 房间名称字数
  PUNCH_LIMIT           = 5                # p2p重试次数
  TO                    = ':'              # 找房间前缀
end
