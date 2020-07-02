# P2p2 - 内网里的任意应用，访问另一个内网里的应用服务端。

访问家里的电脑，需要把电脑上的sshd暴露到外网。暴露到外网，需要端口映射。光猫自带miniupnpd，允许你用upnpc映射一个端口到光猫上，可惜的是，这个映射很容易消失，你也没办法打补丁。

有个彻底的办法：改桥接。自己的机器，自己拨号，自己面向外网，这才是internet！

复杂的来了，如果你的套餐还包含高清iptv，高清iptv需要获取内网ip，需要获取外网ip，它写死了，你不得不兼容它，这可不简单。

也可以不依赖光猫。准备一个外网服务器，充当镜子，把服务映射到镜子上，客户端访问镜子。

但镜子要求流量去服务器上绕一圈，于是只剩下最后一个，最精简的选项：p2p。

由于两头都在nat里，听，是听不到的，必须两头同时发起连接，因此需要一台配对服务器p2pd传递双方地址，地址是浮动的，所以约定一个房间名，ssh连p2，到家。

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

## 使用篇

```bash
gem install p2p2
```

配对服务器：

```ruby
# p2pd.rb
require 'p2p2/p2pd'

P2p2::P2pd.new '/etc/p2p2.conf.json'
```

```bash
ruby p2pd.rb
```

家：

```ruby
# p1.rb
require 'p2p2/p1'

P2p2::P1.new '/boot/p2p2.conf.json'
```

```bash
ruby p1.rb
```

公司：

```ruby
# p2.rb
require 'p2p2/p2'

P2p2::P2.new '/boot/p2p2.conf.json'
```

```bash
ruby p2.rb
```

p2p2.conf.json的格式：

```javascript
// p2p2.conf.json
{
    "p2pd_host": "1.2.3.4",           // 配对服务地址
    "p2pd_port": 2020,                // 配对服务端口
    "room": "libo",                   // 房间名
    "appd_host": "127.0.0.1",         // 应用地址
    "appd_port": 22,                  // 应用端口
    "sdwd_host": "0.0.0.0",           // 代应用地址
    "sdwd_port": 2222,                // 代应用端口
    "p2pd_tmp_dir": "/tmp/p2p2.p2pd", // 配对服务缓存根路径
    "p1_tmp_dir": "/tmp/p2p2.p1",     // p1缓存根路径
    "p2_tmp_dir": "/tmp/p2p2.p2"      // p2缓存根路径
}
```

到家：

```bash
ssh -p2222 libo@localhost
```
