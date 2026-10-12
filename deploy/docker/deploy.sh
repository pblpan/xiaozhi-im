#!/usr/bin/env bash
# ============================================================
#  小智IM 服务端 —— Docker 一键部署脚本（给拿到 tar 包的人用）
#
#  用法（在解压后的 tar 包根目录）：
#    ./deploy.sh            # 首次：生成 .env（强随机密钥/密码）后拉起
#    ./deploy.sh            # 之后：重建并拉起（配置不变则不重新生成 .env）
#    ./deploy.sh down       # 停止并移除容器（数据保留在 ./data）
#    ./deploy.sh logs       # 看服务端日志
#    ./deploy.sh rebuild    # 强制用 Dockerfile.build 重新 npm install 装依赖
#
#  前置：本机已装 Docker + docker compose v2（或 docker-compose）。
#  不需要联网（node_modules 已经打在包里，镜像直接 COPY 用）。
# ============================================================
set -euo pipefail
cd "$(dirname "$0")"

# ---- docker compose 命令适配（v2 的 `docker compose` 与旧版 `docker-compose`）----
if docker compose version >/dev/null 2>&1; then
  DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  DC="docker-compose"
else
  echo "::error::没找到 docker compose / docker-compose，请先安装 Docker。" >&2
  exit 1
fi

CMD="${1:-up}"
REBUILD_DEPS=0
if [ "$CMD" = "rebuild" ]; then
  REBUILD_DEPS=1
  CMD="up"
fi

# ---- 首次生成 .env（强随机密钥 + 管理台初始密码）----
if [ ! -f .env ]; then
  if command -v openssl >/dev/null 2>&1; then
    JWT_SECRET="$(openssl rand -hex 32)"
    ADMIN_PASSWORD="$(openssl rand -base64 18 | tr -dc 'A-Za-z0-9' | head -c 16)"
  else
    JWT_SECRET="$(head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 64)"
    ADMIN_PASSWORD="$(head -c 12 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 16)"
  fi
  cat > .env <<EOF
# 小智IM 服务端运行时配置（首次部署自动生成，可手动改）
# ⚠️ 改完记得 `./deploy.sh` 重新拉起；JWT_SECRET 一旦改了，已登录的会被踢下线。
JWT_SECRET=$JWT_SECRET
ADMIN_USERNAME=admin
ADMIN_PASSWORD=$ADMIN_PASSWORD
MAX_FILE_MB=50

# —— 以下为中继相关，纯内网用不到可以留空（并把 docker-compose.yaml 里的 coturn 服务删掉）——
ICE_STUN=
TURN_URLS=
TURN_USER=xiaozhi
TURN_PASSWORD=
TURN_EXTERNAL_IP=
TURN_INTERNAL_IP=
TURN_REALM=xiaozhi.im
TURN_MIN_PORT=49160
TURN_MAX_PORT=49200
CF_TURN_KEY_ID=
CF_TURN_API_TOKEN=
EOF
  echo "✅ 已生成 .env（管理员初始密码见下方）"
fi

# ---- 决定用哪个 Dockerfile ----
DOCKERFILE="server/Dockerfile.prebuilt"
if [ "$REBUILD_DEPS" = "1" ]; then
  DOCKERFILE="server/Dockerfile.build"
  echo "⚠️ 已指定 rebuild：将用 Dockerfile.build 重新 npm install（需要联网到 npm 源）"
fi

case "$CMD" in
  up)
    echo "==> 构建并启动（使用 $DOCKERFILE）…"
    # compose 里 build.dockerfile 固定指向 Dockerfile.prebuilt（预装依赖，离线可用）。
    $DC up -d --build
    echo ""
    echo "🚀 小智IM 服务端已启动"
    echo "   管理后台： http://<本机IP>:3602/admin"
    echo "   账号：     admin"
    echo "   初始密码： $(grep '^ADMIN_PASSWORD=' .env | cut -d= -f2)"
    echo ""
    echo "   查看日志： ./deploy.sh logs"
    echo "   停止服务： ./deploy.sh down"
    ;;
  rebuild)
    # 用 Dockerfile.build 重新 npm install 装依赖（需要联网到 npm 源），
    # 装好后再用已构建的镜像直接 up（不再 --build）。
    echo "==> 用 Dockerfile.build 重新构建镜像（联网 npm install）…"
    IMGTAG="$(grep -m1 'image:' docker-compose.yaml | sed 's/.*image:[[:space:]]*//')"
    docker build -t "$IMGTAG" -f server/Dockerfile.build server/
    $DC up -d
    echo ""
    echo "🚀 小智IM 服务端已启动（依赖已重新安装）"
    echo "   管理后台： http://<本机IP>:3602/admin"
    echo "   账号：     admin"
    echo "   初始密码： $(grep '^ADMIN_PASSWORD=' .env | cut -d= -f2)"
    ;;
  down)
    $DC down
    ;;
  logs)
    $DC logs -f xiaozhi-im
    ;;
  *)
    echo "用法： ./deploy.sh [up|down|logs|rebuild]" >&2
    exit 1
    ;;
esac
