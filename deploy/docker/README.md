# 小智IM 服务端 —— Docker 部署包（通用免构建版）

本包把小智IM 服务端（Node.js + WebSocket + SQLite + 管理后台）连同**已装好的
依赖**一起打包，拿到任意装了 Docker 的机器上解压、一条命令即可拉起，**无需联网、
无需 npm**。

## 包里有啥

```
小智IM_Docker通用版_<版本>/
├── docker-compose.yaml      # 编排：服务端 + 可选 TURN 中继
├── deploy.sh               # 一键部署（生成密钥/密码 + 拉起）
├── README.md
├── server/                 # 服务端本体（含 node_modules 预装依赖、已构建的管理台 public/）
│   ├── Dockerfile.prebuilt # 预装依赖版镜像（默认用这个，离线）
│   └── Dockerfile.build    # 从 npm 源重装依赖版（需要时切）
├── coturn/                 # TURN 中继配置（纯内网用不到可删）
└── data/                   # 运行时自动生成：数据库、上传文件、授权状态
```

## 一键部署

```bash
# 解压后进入包根目录
./deploy.sh            # 首次：自动生成 .env（强随机 JWT 密钥 + 管理台初始密码），然后拉起
```

启动后：

- 管理后台： `http://<本机IP>:3602/admin`
- 账号： `admin` ／ 初始密码： 看 `deploy.sh` 末尾打印，或 `grep ADMIN_PASSWORD .env`

其它命令：

```bash
./deploy.sh logs     # 看服务端实时日志
./deploy.sh down     # 停止并移除容器（data/ 数据保留）
./deploy.sh rebuild  # 用 Dockerfile.build 重新从 npm 源装依赖（需要联网）
```

## 端口

| 端口      | 协议 | 用途                                         |
|-----------|------|----------------------------------------------|
| 3602      | TCP  | 客户端连接 + 管理后台（http://IP:3602/admin）|
| 3616      | UDP  | 客户端首装的「局域网自动发现」                |

两个端口都要在防火墙/路由器放通。3616 不映射的话，客户端只能手填服务器地址。

## 数据在哪 / 升级 / 换机器

- **数据目录**： 包内的 `./data/`（数据库、上传文件、授权状态都在这里）。
  升级只需重新解压新包、`./deploy.sh` 拉起，**只要 data/ 还在，数据、授权、聊天记录全保留**。
- **授权机器码**： 绑定宿主机 `/etc/machine-id`。换机器 = 机器码变 = 授权失效（防把 data/ 整盘拷走白嫖），
  需在管理台重新出授权码。
- **换授权**： 不要删 `data/`，否则授权记录丢了。

## 音视频中继（TURN）—— 仅外网/跨网段通话需要

纯内网文字/图片不需要。要跨公网或对称 NAT 通话，才需要中继：

1. 本机有**公网 IP**（路由器 WAN 口能看到真实公网地址）；
2. 路由器把 `3478/udp`、`3478/tcp`、`49160-49200/udp` 映射到本机；
3. 在 `.env` 里填 `TURN_EXTERNAL_IP=你的公网IP` 和 `TURN_PASSWORD=一个强口令`，`./deploy.sh` 重启。

没有公网 IP：删掉 `docker-compose.yaml` 里的 `coturn` 服务，改用云 TURN（把
`TURN_URLS` 指过去）。

## 离线 / 内网环境说明

`Dockerfile.prebuilt` 直接 COPY 包里带来的 `node_modules`，**不跑 npm install**，
所以首次 `docker compose up -d --build` 不需要访问 npm 源。唯一需要联网的是
Docker 首次拉 `node:22-slim` 与 `coturn/coturn` 两个基础镜像——如果目标机完全
离线，请在有网的机器上预先 `docker pull node:22-slim` 与 `docker pull coturn/coturn:4.6-alpine`
并 `docker save` 过去 `docker load`。

## 与飞牛 fpk / Windows 安装包的关系

- 这套 Docker 包 = 服务端通用部署形态（任意装了 Docker 的 Linux / macOS / Windows）。
- 飞牛 NAS 用 `小智IM-飞牛安装包-vX.fpk`（应用中心手动安装）。
- Windows 单机用 `小智IM服务端-Setup-vX.exe`（自带 Node 运行时，不用装 Docker）。

三者服务端代码完全一致，只是打包/运行形态不同。
