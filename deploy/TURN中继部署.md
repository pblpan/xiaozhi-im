# TURN 中继部署与排障

> 目的：让**不在同一个网络**的两个人也能接通音视频通话。
>
> 现状（2026-09-11 实测）：
> - coturn 中继已跑在飞牛上，**配置正确、内网可用**；
> - 服务端已能正确把中继地址下发给客户端（`turnConfigured=true`，UDP + TCP 各一条）；
> - 中继功能实测通过：UDP 分配 ✅ / TCP 分配 ✅ / 两端都走中继互发 ✅（均 0% 丢包）；
> - **还差最后一步** —— 把这个中继从公网放进来。见第二节（两条路线，选一条）。

---

## 一、为什么非要中继不可

音视频通话走 WebRTC，默认是两边**点对点直连**，不经过服务器。能不能直连，取决于双方
所处的网络：

| 场景 | 结果 |
| --- | --- |
| 同一个 WiFi / 同一个交换机下 | ✅ 直接连通，不用中继 |
| 一方在家、一方在公司（双方 NAT 都宽松） | ⚠️ 靠 STUN 打洞，**成功率看运气** |
| **手机 4G / 5G** | ❌ 运营商大内网（对称 NAT），**打洞基本无望** |
| 企业专线、酒店 WiFi | ❌ 大多是对称 NAT，打不通 |

打不通时的表现就是「接通后黑屏 / 秒断」或者干脆「一直连不上」。这时候唯一的出路是
**TURN 中继**：由一台公网可达的服务器替双方转发媒体流。

代价是中继的流量走服务器上行，一路 720p 视频约 1.5 Mbps —— 家宽完全扛得住。

---

## 二、怎么把中继放到公网

本项目家宽**没有做任何入站映射**（外部访问小智IM 全靠 ZeroNews 隧道），
所以 coturn 目前只在内网可达。两条路线**任选其一**：

| | 路线 A：路由器端口映射 | 路线 B：ZeroNews TCP 隧道 |
| --- | --- | --- |
| 前提 | 家宽是**真公网 IP** | 无要求（能用 ZeroNews 就行） |
| 要开端口 | 3478/udp、3478/tcp、49160-49200/udp | **只要 3478/tcp 一个** |
| 需要路由器权限 | ✅ 要 | ❌ 不要 |
| 通话质量 | 更好（走 UDP） | 可用（走 TCP 中继） |
| 难度 | 中（可能还要动光猫） | 低（网页控制台点几下） |

> 先试 B 更省事；B 通了就不用碰路由器。想要更好的通话质量再考虑 A。

---

### 路线 A：路由器端口映射

**前提**：你家宽带拿到的是**真公网 IP**，不是运营商大内网地址。

#### A.1 先确认有没有公网 IP

登录路由器管理页（本项目是小米路由器，`192.168.31.1`），找「WAN 口信息 / 外网设置」，
看 WAN IP：

- 是 `100.64.x.x`、`10.x.x.x`、`172.16~31.x.x` → **运营商大内网，此方案走不通**，转路线 B
- 是其他公网地址（本项目实测出口为 `112.99.176.76`）→ **可以，继续往下**

#### A.2 加三条端口映射

在路由器的「端口转发 / 虚拟服务器 / NAT 映射」里加这三条，**内网地址都填飞牛的
`192.168.31.44`**：

| 名称 | 协议 | 外部端口 | 内部端口 | 内网 IP |
| --- | --- | --- | --- | --- |
| xiaozhi-turn | UDP | 3478 | 3478 | 192.168.31.44 |
| xiaozhi-turn-tcp | TCP | 3478 | 3478 | 192.168.31.44 |
| xiaozhi-turn-relay | UDP | 49160-49200 | 49160-49200 | 192.168.31.44 |

> **端口范围**：部分路由器不支持范围映射，只允许一条一个端口。那就先加
> `49160`、`49161` 两条（够 1 路通话用），再加 `49162`、`49163` 就是 2 路。
> 上限 49200，按需增加即可；范围越大能同时进行的通话越多。
>
> **光猫 + 路由器两级**：如果光猫是「路由模式」，还要在光猫里同样做一遍（或把光猫
> 改成桥接模式，由路由器拨号）。这是最容易漏的一步。

#### A.3 地址已经配好了，不用手动改

飞牛上的 `docker/.env` 里已经有（安装脚本每次安装/升级都会自动重探公网 IP）：

```
TURN_EXTERNAL_IP=112.99.176.76
TURN_URLS=turn:112.99.176.76:3478?transport=udp,turn:112.99.176.76:3478?transport=tcp
```

映射生效后**不需要改任何配置**，端口一通就通了。想确认下发是否正常：

```bash
curl -s http://192.168.31.44:3602/api/call/ice
# 期望：iceServers 里有一项 turn:...，且 turnConfigured 为 true
```

**客户端不用重装** —— ICE 配置由服务端下发，改完立刻对新通话生效。

---

### 路线 B：ZeroNews TCP 隧道（推荐先试这条）

ZeroNews 目前已经把小智IM 服务端（`127.0.0.1:3602`）以 **TCP** 隧道放到了公网，
这也是现在外网能用 App 的原因。coturn 同样支持 **TURN over TCP**，
所以我们只要再开**一个 TCP 隧道口**，就能把中继放出去：

1. 登录 ZeroNews 控制台 →「隧道管理」→ 新建隧道
2. 协议选 **TCP**，内网地址 `192.168.31.44`，内网端口 **3478**
3. 公网端口随意（记下来，比如 `3478` 或控制台分配的端口）
4. 假设分配的公网入口是 `xxx.zeronews.cc:端口`

然后把飞牛 `docker/.env` 里的地址改成这个公网入口：

```bash
sudo nano /vol1/@appcenter/xiaozhi-im/docker/.env
```

```
TURN_EXTERNAL_IP=<公网入口的IP或域名>
TURN_URLS=turn:<公网入口的IP或域名>:<公网端口>?transport=tcp
```

> ⚠️ 注意这里 **`transport=tcp`**，而且只留 TCP 一条。
> 因为 ZeroNews 走的是 TCP 隧道，UDP 那条地址在外面根本不通，
> 留着只会让客户端多试一次、多等一会儿。

改完重建容器：

```bash
cd /vol1/@appcenter/xiaozhi-im/docker
sudo docker compose up -d --force-recreate coturn xiaozhi-im
```

**为什么这条能成立**（已验证）：通话两端都连到同一个 coturn 上，
各自把自己的媒体流用 TURN 协议**封在自己的 TCP 连接里**发给服务器，
服务器再把两路对接起来。整个过程服务器不出公网，
所以不需要暴露 `49160-49200` 那 41 个 UDP 中继端口。

工程上还做了一件事让这条更稳：coturn 的 `external-ip` 用了
**「公网/内网」双地址**写法（实测渲染结果 `external-ip=112.99.176.76/192.168.31.44`）。
这样服务器发现「对方候选其实就是我自己」，会直接在内网侧投递，
不再绕出去打一圈 NAT 回环 —— 家用路由器普遍不支持回环，不写这一项这种
「两端都走中继」的通话仍会失败。

---

## 三、怎么验证真的通了

### 3.1 服务端自检（在飞牛上执行）

```bash
# ① 中继容器在不在跑
sudo docker ps --filter name=xiaozhi-im-turn

# ② 看生效的中继配置（含双地址）
sudo docker exec xiaozhi-im-turn grep -E '^(external-ip|min-port|max-port)' /tmp/turnserver.conf
# 期望：external-ip=112.99.176.76/192.168.31.44
#       min-port=49160 / max-port=49200

# ③ 两个协议都在听
ss -lunp | grep -c 3478    # UDP，非 0
ss -ltnp | grep -c 3478    # TCP，非 0

# ④ 签发配置里有没有中继
curl -s http://127.0.0.1:3602/api/call/ice
# 期望：turnConfigured=true，且 urls 里含 turn:...
```

### 3.2 中继本身能不能用（飞牛上执行，不用外网）

```bash
# UDP 中继
sudo docker exec xiaozhi-im-turn turnutils_uclient -T \
  -u xiaozhi -w xiaozhi-turn-2026 -p 3478 -n 3 -m 1 127.0.0.1 | tail -3

# TCP 中继（隧道方案靠的就是它）
sudo docker exec xiaozhi-im-turn turnutils_uclient -T -t \
  -u xiaozhi -w xiaozhi-turn-2026 -p 3478 -n 3 -m 1 127.0.0.1 | tail -3

# 两端都走中继互发（最接近真实跨网通话）
sudo docker exec xiaozhi-im-turn turnutils_uclient -T -y \
  -u xiaozhi -w xiaozhi-turn-2026 -p 3478 -n 3 -m 1 127.0.0.1 | tail -3
```

三条都期望 `Total lost packets 0 (0.000000%)`。
（本项目 2026-09-11 实测三条全部通过。）

### 3.3 从外网验证（必须用手机流量，不能连家里 WiFi）

用手机（**关掉 WiFi，只用 4G/5G**）打开客户端，和另一个同样不在你家网络的人通话。
也可以在手机浏览器打开 <https://check-host.net/check-tcp?host=你的公网IP:3478>
看 TCP 端口是否可达。

### 3.4 客户端侧看诊断

通话页**长按对方名字**会弹出接收诊断信息，里面会写明：

- `ICE 配置已下发：N 项，含 TURN 中继` —— 配置拿到了
- `ICE 配置已下发：N 项，仅 STUN 无中继` —— 服务端没配 TURN_URLS，跨网通话打不通
- `拉取 ICE 配置失败（…），改用内置 STUN` —— 连服务端都没拉通

---

## 四、常见问题

**Q：内网通话正常，外网就是不行？**
按顺序查：① `curl /api/call/ice` 里 `turnConfigured` 是不是 `true`；
② 中继端口有没有真的放出去（路线 A 的路由器映射 / 路线 B 的 3478/tcp 隧道）；
③ 手机流量下的实际通话试了吗。

**Q：接口返回 `turnConfigured: false`，但我明明起了中继容器？**
这是 v0.6.1 的一个真实缺陷，**v0.6.2 已修**：光起了 coturn 容器，但服务端 `.env` 里
没有 `TURN_URLS`，服务端就不知道中继地址，自然不下发给客户端 —— 容器白跑。
检查并补上：

```bash
grep -E '^TURN' /vol1/@appcenter/xiaozhi-im/docker/.env
# 没有 TURN_URLS 就手动补，然后重建：
cd /vol1/@appcenter/xiaozhi-im/docker && sudo docker compose up -d
```

**Q：改了 `.env` 也 `compose up -d` 了，怎么还是老配置？**
`compose up -d` 只在**容器定义**变化时重建；改挂载进去的文件（如
`coturn/turnserver.conf`）和 `.env` 未必触发重建。强制重建：

```bash
cd /vol1/@appcenter/xiaozhi-im/docker
sudo docker compose up -d --force-recreate coturn xiaozhi-im
```

**Q：通话接不通，但对方来电界面根本不弹？**
这**不是**中继问题，是中继解决不了的信令问题。已经修过（v0.6.1）：
长连接断线不再放弃重连、掉线 20 秒内重连回来会自动补弹来电界面。
如果还出现，看客户端是否已升级到 v0.6.1 及以上。

**Q：中继会不会很占带宽？**
单路 720p 约 1.5 Mbps。`turnserver.conf` 里已限制 `max-bps=1000000`（1 Mbps/会话）
和 `user-quota=12`，防止被当中转代理滥用。不够用可以调大。

**Q：公网 IP 会变怎么办？**
`external-ip` 是容器启动时自动探测的，飞牛的安装脚本每次安装/升级也会重探一次写进
`.env`。IP 变了重启一下容器即可：

```bash
cd /vol1/@appcenter/xiaozhi-im/docker && sudo docker compose restart coturn
```

**Q：两条路线都搞不定？**
退路是租一台最便宜的云服务器（约 ¥30/月）跑同一份 coturn，把 `TURN_URLS` 指过去。
把 `deploy/coturn/` 整个目录拷过去，`docker compose up -d` 即可 —— 配置是通用的。
