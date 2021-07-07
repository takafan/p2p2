# P2p2

p2p2，连回家。

最直接的办法：p2p。

```
                paird
                ^  ^
               ^    ^
   “周立波的房间”     “周立波的房间”
   ^                         ^
  ^                         ^
p1 --> nat --><-- nat <-- p2
```

问配对服务拿对方外网地址，tcp同时连接。

通道可以建在任意被割裂的客户端-服务端应用之间。

```
ssh --> p2 --> p1 --> sshd

远程桌面 --> p2 --> p1 --> pc
```

移动宽带tcp握手握不进去，想连进去只能靠udp p2p，或者用我的另一个库 girl/mirrord。

## 使用篇

```bash
gem install p2p2
```

配对服务器：

```ruby
# paird.rb
require 'p2p2/paird'

P2p2::Paird.new '/etc/p2p2.conf.json'
```

```bash
ruby paird.rb
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
    "paird_host": "1.2.3.4",  // 配对服务地址
    "paird_port": 4040,       // 配对服务端口
    "infod_port": 4050,       // 查询服务，供配对服务器本机调用
    "room": "libo",           // 房间名
    "appd_host": "127.0.0.1", // p1端内网应用地址
    "appd_port": 22,          // 应用端口
    "shadow_port": 2222       // p2端影子端口
}
```

走起：

```bash
ssh -p2222 libo@localhost
```
