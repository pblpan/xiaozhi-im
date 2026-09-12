# TURN 中继部署与排障

> 目的：让**不在同一个网络**的两个人也能接通音视频通话。
>
> 现状（2026-09-12 实测）：
> - 服务端已能正确下发中继配置（`GET /api/call/ice` 返回 `turnConfigured=true`）；
> - 自建 coturn 跑在飞牛上，**配置正确、内网可用**，UDP/TCP 分配与两端互发三连全通（0% 丢包）；
> - 家宽**没有任何入站映射**（外网访问小智IM 全靠 ZeroNews 隧道），所以自建 coturn
>   的公网端口目前**进不来**；
> - **ZeroNews 免费版不支持 TCP / UDP 隧道**（只有 HTTPS），所以「靠隧道放通中继」这条
>   走不通 —— 需要付费档（个人职业 ¥22/月）。
>
> 因此推荐走 **路线 A：Cloudflare 托管中继**，不用碰路由器、不用买隧道。

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

## 二、三条路线怎么选

| | **A. Cloudflare 托管中继** | B. 自建 coturn + 路由器映射 | C. 自建 coturn + 隧道 |
| --- | --- | --- | --- |
| 前提 | 无（能上外网即可） | 家宽是**真公网 IP** | 隧道服务支持 TCP/UDP |
| 要开端口 | **一个都不用** | 3478/udp、3478/tcp、49160-49200/udp | 至少 3478/tcp |
| 要碰路由器 | ❌ 不要 | ✅ 要 | ❌ 不要 |
| 成本 | 免费额度 **1TB/月** | 免费 | ZeroNews 需 ¥22/月起 |
| 延迟 | 较好（走 443/TLS 出站） | 最好（走 UDP 直连） | 一般（走 TCP 中继） |
| 难度 | **最低** | 中（可能还要动光猫） | 中 |

> **先做 A。** 做完 A 就已经能跨网通话了；想要更低的延迟再考虑叠加 B。

三条路线**可以同时配**，服务端会把能用的中继都下发，客户端自己挑通的那条，不会互相干扰。

---

## 三、路线 A：Cloudflare 托管中继（推荐）

### 为什么它绕开了所有麻烦

自建 coturn 的核心难点是「公网必须能把 UDP/TCP 打进家里」。Cloudflare TURN 反过来 ——
客户端**只用出站连接**，走 `443/TLS`，任何网络都出得去，所以：

- 不需要公网 IP
- 不需要路由器端口映射
- 不需要内网穿透隧道

本项目实测（黑龙江家宽）：

| 目标 | 结果 |
| --- | --- |
| `stun.cloudflare.com:3478`（UDP） | ✅ 233ms |
| `turn.cloudflare.com:80`（TCP 备用口） | ✅ 278ms |
| `turn.cloudflare.com:5349`（TURN over TLS） | ✅ 199ms |
| `turn.cloudflare.com:443`（TLS 备用口） | ✅ 196ms |
| `rtc.live.cloudflare.com:443`（签发凭据的接口） | ✅ 426ms |

> 顺带一提：`stun.qq.com:3478` 在本机是**被 RST 的**，所以它已被从 STUN 列表里剔除。

### A.1 开通（一次性，5 分钟）

1. 登录 <https://dash.cloudflare.com>（免费账号即可）
2. 左侧进 **Realtime**（旧名 Calls）→ **TURN keys** → **Create**
3. 记下两项：
   - **Key ID**（一串 UUID）
   - **API Token**（创建时选 scope：**Calls: Edit**）—— 只在创建时显示一次
4. 免费额度：**1000 GB/月**，之后 $0.05/GB。按 1.5 Mbps 算，1TB 够跑 **约 1500 小时**通话。

### A.2 填进飞牛的 `.env`

```bash
sudo nano /vol1/@appcenter/xiaozhi-im/docker/.env
```

加上（或修改）这两行：

```
CF_TURN_KEY_ID=你的KeyID
CF_TURN_API_TOKEN=你的APIToken
```

> **不用填 TURN_URLS。** 地址由 Cloudflare 在签发时一并给出，
> 服务端会自动拼进 `/api/call/ice` 的下发结果里。

### A.3 重建容器

```bash
cd /vol1/@appcenter/xiaozhi-im/docker
sudo docker compose up -d --force-recreate xiaozhi-im
```

### A.4 验证

```bash
curl -s http://127.0.0.1:3602/api/call/ice | head -c 800
```

期望看到：

- `"turnConfigured": true`
- `"turnSources": ["cloudflare"]`（若同时配了自建 coturn，则是 `["cloudflare","static"]`）
- `iceServers` 里出现 `turn:turn.cloudflare.com:3478?...` 与 `turns:turn.cloudflare.com:5349?...`
- 没有 `cloudflareError` 字段（有的话会写明是 HTTP 401 还是超时）

**客户端不用重装** —— ICE 配置由服务端下发，改完立刻对新通话生效。

> ⚠️ `.env` 里的 `CF_TURN_KEY_ID` / `CF_TURN_API_TOKEN` 在 fpk 安装/升级时**会被保留**
> （安装脚本会先读出来再写回去），不必担心升级把它们冲掉。

---

## 四、路线 B：自建 coturn + 路由器端口映射

**前提**：你家宽带拿到的是**真公网 IP**，不是运营商大内网地址。

### B.1 先确认有没有公网 IP

登录路由器管理页（本项目是小米路由器，`192.168.31.1`），找「WAN 口信息 / 外网设置」，
看 WAN IP：

- 是 `100.64.x.x`、`10.x.x.x`、`172.16~31.x.x` → **运营商大内网，此方案走不通**，用路线 A
- 是其他公网地址（本项目实测出口为 `112.99.176.76`）→ **可以，继续往下**

### B.2 加三条端口映射

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

### B.3 地址已经配好了，不用手动改

飞牛上的 `docker/.env` 里已经有（安装脚本每次安装/升级都会自动重探公网 IP）：

```
TURN_EXTERNAL_IP=112.99.176.76
TURN_URLS=turn:112.99.176.76:3478?transport=udp,turn:112.99.176.76:3478?transport=tcp
```

映射生效后**不需要改任何配置**，端口一通就通了。

---

## 五、路线 C：自建 coturn + 隧道

**⚠️ 先看这条：ZeroNews 免费版不支持 TCP / UDP 隧道**，免费档只有 HTTPS。
所以这条路必须先把 ZeroNews 升到「个人职业」（¥22/月）及以上，或者换一个支持
TCP/UDP 的隧道服务。

> 只走 HTTPS 隧道是**放不出 TURN 的** —— TURN 客户端连的是裸 TCP/UDP，
> 不是 HTTP，套不进 HTTPS 隧道。

满足前提后：

1. 控制台 →「隧道管理」→ 新建隧道
2. 协议选 **TCP**，内网地址 `192.168.31.44`，内网端口 **3478**
3. 公网端口尽量填 `3478`（**公网与内网端口一致最省事**）
4. 假设公网入口是 `xxx.example.com:3478`

然后改 `.env`：

```
TURN_EXTERNAL_IP=<公网入口的IP或域名>
TURN_URLS=turn:<公网入口的IP或域名>:<公网端口>?transport=tcp
```

> ⚠️ 这里 **`transport=tcp`**。隧道走的是 TCP，UDP 那条地址在外面根本不通，
> 留着只会让客户端多试一次、多等一会儿。

改完重建：

```bash
cd /vol1/@appcenter/xiaozhi-im/docker
sudo docker compose up -d --force-recreate coturn xiaozhi-im
```

**为什么这条能成立**（已实测验证）：通话两端都连到同一个 coturn 上，
各自把媒体流用 TURN 协议**封在自己的 TCP 连接里**发给服务器，服务器再把两路对接起来。
整个过程服务器不出公网，所以**不需要**暴露 `49160-49200` 那 41 个 UDP 中继端口。

工程上还做了一件事让这条更稳：coturn 的 `external-ip` 用了**「公网/内网」双地址**写法
（实测渲染结果 `external-ip=112.99.176.76/192.168.31.44`）。这样服务器发现「对方候选
其实就是我自己」时会直接在内网侧投递，不再绕出去打一圈 NAT 回环 ——
家用路由器普遍不支持回环，不写这一项这种「两端都走中继」的通话仍会失败。

---

## 六、怎么验证真的通了

### 6.1 一条命令查完（推荐）

```bash
python deploy/turn_status.py
```

这个脚本会依次检查：容器状态 / ICE 下发 / 渲染后的配置 / 3478 双协议监听 /
UDP 分配 + TCP 分配 + 两端走中继互发。只读，不改任何配置。

### 6.2 手动分步查（在飞牛上执行）

```bash
# ① 中继容器在不在跑
sudo docker ps --filter name=xiaozhi-im-turn

# ② 看**生效**的中继配置（注意不是挂载进去的模板，模板里还是占位符）
sudo docker exec xiaozhi-im-turn grep -E '^(external-ip|min-port|max-port)' /tmp/turnserver.conf
# 期望：external-ip=112.99.176.76/192.168.31.44
#       min-port=49160 / max-port=49200

# ③ 两个协议都在听
ss -lunp | grep -c 3478    # UDP，非 0
ss -ltnp | grep -c 3478    # TCP，非 0

# ④ 下发里有没有中继
curl -s http://127.0.0.1:3602/api/call/ice
# 期望：turnConfigured=true，urls 里含 turn:/turns:
```

### 6.3 中继本身能不能用（飞牛上执行，不用外网）

```bash
# UDP 中继
sudo docker exec xiaozhi-im-turn turnutils_uclient -T \
  -u xiaozhi -w xiaozhi-turn-2026 -p 3478 -n 3 -m 1 127.0.0.1 | tail -3

# TCP 中继
sudo docker exec xiaozhi-im-turn turnutils_uclient -T -t \
  -u xiaozhi -w xiaozhi-turn-2026 -p 3478 -n 3 -m 1 127.0.0.1 | tail -3

# 两端都走中继互发（最接近真实跨网通话）
sudo docker exec xiaozhi-im-turn turnutils_uclient -T -y \
  -u xiaozhi -w xiaozhi-turn-2026 -p 3478 -n 3 -m 1 127.0.0.1 | tail -3
```

三条都期望 `Total lost packets 0 (0.000000%)`。

> 只测**自建**中继时才需要这三条。走路线 A（Cloudflare）不用测，它不在你家。

### 6.4 从外网验证（必须用手机流量，不能连家里 WiFi）

用手机（**关掉 WiFi，只用 4G/5G**）打开客户端，和另一个同样不在你家网络的人通话。

> 在家里测公网 IP:3478 是**测不准的**：本机和 NAS 是同一个出口，
> 「没做映射」和「路由器不支持 NAT 回环」表现一样，都是超时。

### 6.5 客户端侧看诊断

通话页**长按对方名字**会弹出接收诊断信息，里面会写明：

- `ICE 配置已下发：N 项，含 TURN 中继` —— 配置拿到了
- `ICE 配置已下发：N 项，仅 STUN 无中继` —— 服务端没配中继，跨网通话打不通
- `拉取 ICE 配置失败（…），改用内置 STUN` —— 连服务端都没拉通

---

## 七、常见问题

**Q：`turnConfigured` 是 `true`，中继也下发了，外网还是打不通？**
先确认走的是哪条路线：路线 A（Cloudflare）不依赖你家网络，下了就应该能通；
路线 B/C 则要确认端口**真的**从公网进得来（用手机流量实测，别在家里测）。

**Q：配了 Cloudflare，接口返回 `cloudflareError: "HTTP 401 ..."`？**
API Token 不对或没给 `Calls: Edit` 权限，重新生成一个。

**Q：配了 Cloudflare，接口里却没有 `turn:` 项？**
`CF_TURN_KEY_ID` / `CF_TURN_API_TOKEN` 有一项是空的（两个都要填），
或者改完 `.env` 没有 `--force-recreate`。

**Q：接口返回 `turnConfigured: false`，但我明明起了中继容器？**
v0.6.1 的一个真实缺陷，**v0.6.2 已修**：光起了 coturn 容器，但服务端 `.env` 里
没有 `TURN_URLS`，服务端不知道中继地址，自然不下发 —— 容器白跑。
用路线 A 时看 `CF_TURN_KEY_ID` 有没有填。

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
走 Cloudflare 时按 egress 计量，免费 1TB/月。走自建 coturn 时，
`turnserver.conf` 里已限制 `max-bps=1000000`（1 Mbps/会话）和 `user-quota=12`，
防止被当中转代理滥用。不够用可以调大。

**Q：公网 IP 会变怎么办？**
自建 coturn 的 `external-ip` 是容器启动时自动探测的，飞牛安装脚本每次安装/升级也会
重探一次写进 `.env`。IP 变了重启一下容器即可：

```bash
cd /vol1/@appcenter/xiaozhi-im/docker && sudo docker compose restart coturn
```

**Q：自建中继的 relay 端口要开 41 个，太麻烦？**
只走 TCP 中继（路线 C）就**一个端口都不用开**（只要隧道通 3478/tcp），
因为那时媒体全封在 TCP 连接里，不占 UDP relay 端口。

---

## 八、Cloudflare TURN 的已知限制

- Cloudflare 的**中国网络节点不参与 Realtime 流量**，所以从国内连过去会到境外节点。
  本项目实测 TCP 握手约 **200ms**，通话可用；对延迟极度敏感的场景可以叠加自建 coturn。
- 单个中继分配有限制：出站/入站速率 >50-100 Mbps、包速率 >5-10 kpps 会被丢包。
  1v1 通话远达不到这个量级，不用管。
- 它是**中继**，媒体仍由 WebRTC 端到端加密（DTLS-SRTP），Cloudflare 只能转发密文，
  看不到内容。
