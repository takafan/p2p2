# P2p2

p2p2，一根通道，连回家。

不够直接，中转不够直接。

```
               mirror
               ^v   v^
              ^v     v^
   “周立波的房间”     “周立波的房间”
  ^v                           v^
 ^v                             v^
p1                               p2
```

什么是直接？

```
                paird
                ^  ^
               ^    ^
   “周立波的房间”     “周立波的房间”
   ^                         ^
  ^                         ^
p1 --> nat --><-- nat <-- p2
```

p2p直连，问配对服务拿对方外网地址，穿出自己内网，穿进对方内网。

通道可以建在任意被割裂的客户端-服务端应用之间。

```
ssh --> p2 --> p1 --> sshd

远程桌面 --> p2 --> p1 --> pc
```

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
