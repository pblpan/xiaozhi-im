#!/bin/bash
# ============================================================
#  _xiaozhi_common.sh — 小智IM 安装/升级 共享逻辑
#  被 install_callback / upgrade_callback source。
#  1) 兜底创建持久化目录（data-share 通常已由 appcenter 建好）
#  2) 首次安装生成随机 JWT 密钥并写 docker/.env；升级复用旧密钥
#  3) 释放 3602 端口（清理旧版裸容器/旧容器名）
#  4) docker compose up -d 启动（依赖已随包预打包，无需 build/现场 npm install）
#  仅定义函数；由调用方组织执行顺序。
# ============================================================
set +e

APPNAME="xiaozhi-im"
PORT="3602"
TRIM_APPDEST=$(echo "${TRIM_APPDEST}" | sed 's:/*$::')
SHARE_DIR=""

# 数据共享目录：优先 /var/apps/<app>/shares（appcenter 按 data-share 声明创建），
# 兼容无 /var/apps 的旧版 fnOS -> 落到 @appshare
xiaozhi_detect_share() {
  SHARE_DIR=""
  if [ -d "/var/apps/$APPNAME/shares/$APPNAME" ]; then
    SHARE_DIR="/var/apps/$APPNAME/shares/$APPNAME"
  fi
  for v in /vol1 /vol2 /vol3 /vol4; do
    if [ -z "$SHARE_DIR" ] && [ -d "$v/@appshare/$APPNAME" ]; then
      SHARE_DIR="$v/@appshare/$APPNAME"
    fi
  done
  [ -z "$SHARE_DIR" ] && SHARE_DIR="/var/apps/$APPNAME/shares/$APPNAME"
  mkdir -p "$SHARE_DIR/data" "$SHARE_DIR/files" 2>/dev/null
  chmod -R 777 "$SHARE_DIR" 2>/dev/null
  echo "[$APPNAME] SHARE_DIR=$SHARE_DIR"
}

# 生成随机密钥（openssl -> base64 -> od 三级回退）
xiaozhi_gen_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  elif command -v base64 >/dev/null 2>&1; then
    head -c 48 /dev/urandom | base64 | tr -d '\n+/=' | cut -c1-64
  else
    head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}

# 写 docker/.env（保留已有密钥：升级不踢全员重新登录）
xiaozhi_env() {
  local ENV_FILE="${TRIM_APPDEST}/docker/.env"
  [ -z "$TRIM_APPDEST" ] && ENV_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/docker/.env"
  mkdir -p "$(dirname "$ENV_FILE")"

  local SECRET=""
  local OLD_IP=""
  if [ -f "$ENV_FILE" ]; then
    SECRET=$(grep -E '^JWT_SECRET=' "$ENV_FILE" | tail -1 | cut -d= -f2-)
    OLD_IP=$(grep -E '^TURN_EXTERNAL_IP=' "$ENV_FILE" | tail -1 | cut -d= -f2-)
  fi
  [ -z "$SECRET" ] && SECRET=$(xiaozhi_gen_secret)

  # 公网 IP：每次安装/升级都重探（家宽基本是动态 IP，写死过几天就失效）。
  # 探测失败时沿用上次的值 —— 别把一份可能还能用的配置擦成空的。
  local PUBIP=""
  for u in https://ipinfo.io/ip https://api.ipify.org https://ifconfig.me/ip; do
    PUBIP=$(curl -s -m 6 "$u" 2>/dev/null | tr -d '[:space:]')
    case "$PUBIP" in
      [0-9]*.[0-9]*.[0-9]*.[0-9]*) break ;;
      *) PUBIP="" ;;
    esac
  done
  [ -z "$PUBIP" ] && PUBIP="$OLD_IP"

  local TURN_IP_LINE="# 未探测到公网 IP，TURN 中继仅内网可用"
  local TURN_URL_LINE="# TURN_URLS="
  if [ -n "$PUBIP" ]; then
    TURN_IP_LINE="TURN_EXTERNAL_IP=$PUBIP"
    TURN_URL_LINE="TURN_URLS=turn:$PUBIP:3478?transport=udp"
  fi

  cat > "$ENV_FILE" <<EOF
# 由安装/升级回调自动生成，请勿手改
TRIM_APPDEST=$TRIM_APPDEST
XIAOZHI_DATA_DIR=$SHARE_DIR/data
JWT_SECRET=$SECRET

# ---- TURN 中继（跨网络音视频通话必需）----
# 写了地址不等于外网就能用：还要让下面这些入口能从公网进来，
#   3478/udp + 3478/tcp（信令/分配）
#   49160-49200/udp（中继通道）
# 二选一：
#   A) 路由器端口映射（家宽有公网 IP 时最简单）
#   B) ZeroNews 等内网穿透开 UDP 隧道（无公网 IP 时）
# 一条都没打通的话，跨网通话仍会失败（同网段通话不受影响）。
$TURN_IP_LINE
$TURN_URL_LINE
EOF
  echo "[$APPNAME] 已写入 $ENV_FILE (TURN_EXTERNAL_IP=${PUBIP:-无})"
}

# 释放端口：清理同名旧容器
xiaozhi_cleanup() {
  for c in xiaozhi-im xiaozhi_im xiaozhi-im-server; do
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$c"; then
      echo "[$APPNAME] 停止旧容器 $c（释放 $PORT 端口）"
      docker stop "$c" 2>/dev/null
      docker rm -f "$c" 2>/dev/null
    fi
  done
  docker network rm xiaozhi-im_default 2>/dev/null
}

# compose up（依赖预打包，无需 build）
xiaozhi_up() {
  local D="${TRIM_APPDEST}/docker"
  [ -z "$TRIM_APPDEST" ] && D="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/docker"
  if [ -d "$D" ]; then
    cd "$D"
    docker compose up -d 2>&1 || true
  fi
}
