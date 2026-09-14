# 小智 IM 部署

服务端是一个 Node.js 应用（含 Vue 管理后台），可跑在任意 Linux（飞牛/群晖/绿联/麒麟）或容器中。

## 一、Docker 部署（通用 Linux NAS）
```bash
# 1. 在 server/ 目录下构建镜像（需 Docker）
docker build -f deploy/Dockerfile -t xiaozhi-im-server:0.1.0 ./server

# 2. 用 compose 启动（数据持久化到 ./data）
JWT_SECRET=$(openssl rand -hex 16) ADMIN_PASSWORD='你的强密码' \
  docker compose -f deploy/docker-compose.yaml up -d

# 3. 访问
#    管理后台: http://<NAS_IP>:3602/admin   (admin / 上面设的密码)
#    WebSocket: ws://<NAS_IP>:3602/ws
```

## 二、飞牛 FnOS fpk 安装包
> 飞牛 Docker 模式要求**预构建镜像**（飞牛不会现场 build），见上一步先把
> `xiaozhi-im-server:0.1.0` 镜像 load 进飞牛。

```bash
# 在本机（有 node + docker + fnpack 环境）执行：
bash deploy/fpk/build_fpk.sh
# 产出 deploy/xiaozhi-im.fpk
```
把 `xiaozhi-im.fpk` 上传到飞牛「应用中心 → 设置 → 手动安装」即可，桌面出图标、点开即用。

> `manifest` 字段名以飞牛 fnpack 实际规范为准，可按需微调；
> `ICON.png` 需自行放置到 `deploy/fpk/ICON.png`（建议 256x256）。

## 三、重要安全提醒

- 上线前务必修改 `JWT_SECRET` 与 `ADMIN_PASSWORD`（环境变量）。
- **`TURN_PASSWORD` 没有默认值，这是刻意的**。中继口令等于「谁拿到谁就能用你家上行
  带宽转发音视频」，而这个仓库是公开的 —— 所以 compose 里不再兜底任何默认口令，
  缺了 coturn 会**拒绝启动**并在日志里指出该补哪一行。
  · 用 fpk 安装包：安装脚本首次安装自动生成强随机口令，写进 `docker/.env`，
    同时同步到共享目录的 `turn.env`（服务端优先读它），升级时沿用不换；
  · 手工 docker 部署：自己生成一个，`TURN_PASSWORD=$(openssl rand -hex 32)` 传给 compose，
    并把同一个值写进 `turn.env` 的 `TURN_CREDENTIAL`。**两边不一致时中继会认证失败**，
    表现为「同 WiFi 通话正常、跨网一连就断」，很难查。
  · 只改 `.env` 不改 `turn.env` 同样会不一致 —— 改完务必
    `docker compose up -d --force-recreate coturn xiaozhi-im`（环境变量只在容器创建时生效）。
- 对外暴露建议前置 Nginx + HTTPS，客户端 `BASE_URL` 指向 `https://域名`，
  Android 端即可去掉明文 HTTP 配置。
- 数据库与上传文件均在 `/data`（飞牛映射到 `/volx/@appdata/xiaozhi-im`），记得备份。
