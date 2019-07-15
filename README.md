# P2p2 - 内网里的任意应用，访问另一个内网里的应用服务端。

访问家里的电脑，需要把电脑上的sshd暴露到外网。暴露到外网，需要端口映射。光猫自带miniupnpd，允许你用upnpc映射一个端口到光猫上，可惜的是，这个映射很容易消失，你也没办法打补丁。

有个彻底的办法：改桥接。自己的机器，自己拨号，自己面向外网，这才是internet！

复杂的来了，如果你的套餐还包含高清iptv，高清iptv需要获取内网ip，需要获取外网ip，它写死了，你不得不兼容它。第一步，为它分配内网ip的时候要传特殊的dhcp-option，第二步，带它去vlan85领外网ip，然后就能看了。

厌倦了hack，也可以不依赖光猫。准备一个外网服务器，充当镜子，把服务映射到镜子上，客户端访问镜子。

但镜子需要额外产生一份流量在服务器身上，上下行速度取决于服务器的远近和带宽。所以，如果是ssh、sftp、远程桌面，p2p更加合适。

由于两头都在nat里，听，是听不到的，必须两头同时发起连接，因此需要一台配对服务器p2pd传递双方地址。地址是浮动的，所以约定一个房间名。ssh连p2，到家。

1.
```
                  p2pd
                  ^  ^
                 ^    ^
     “周立波的房间”     “周立波的房间”
     ^                         ^
    ^                         ^
  p1 --> nat --><-- nat <-- p2
```

2.
```
  ssh --> p2 --> (encode) --> p1 --> (decode) --> sshd
```

安装：

```bash
gem install p2p2
```

配对服务器：

```ruby
require 'p2p2/p2pd'

P2p2::P2pd.new( 5050 ).looping
```

家：

```ruby
require 'p2p2/p1'

P2p2::P1.new( 'your.server.ip', 5050, '127.0.0.1', 22, '周立波' ).looping
```

公司：

```ruby
require 'p2p2/p2'

P2p2::P2.new( 'your.server.ip', 5050, '0.0.0.0', 2222, '周立波' ).looping
```

ssh:

```bash
ssh -p2222 libo@localhost
```
