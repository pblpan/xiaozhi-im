#!/bin/bash
# ============================================================
#  _xiaozhi_common.sh — 小智IM 安装/升级 共享逻辑
#  被 install_callback / upgrade_callback source。
#  1) 兜底创建持久化目录（data-share 通常已由 appcenter 建好）
#  2) 首次安装生成随机 JWT 密钥并写 docker/.env；升级复用旧密钥
#  3) 释放 3602 端口（清理旧版裸容器/旧容器名）
#  4) docker compose up -d --force-recreate 启动（依赖已随包预打包，无需 build）
#     —— 必须 force-recreate：fnOS 会在 init 与 callback 之间自己跑一次 compose，
#        用裸 up -d 的话 callback 重写的 .env 永远进不了容器（详见 xiaozhi_up 注释）
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

# 历史上写死过的公开默认中继口令 —— 出现在 .env / turn.env 里都等于没设
XIAOZHI_TURN_PASS_LEGACY="xiaozhi-turn-2026"

# 判断一个中继口令是否「等于没设」：空、或还是那个公开默认值
xiaozhi_turn_pass_weak() {
  [ -z "$1" ] && return 0
  [ "$1" = "$XIAOZHI_TURN_PASS_LEGACY" ] && return 0
  return 1
}

# 就地设置 turn.env 里的某个键（保留文件里其它键，不动 Cloudflare 凭据）
# 用法：xiaozhi_turn_env_set <文件> <键> <值>
xiaozhi_turn_env_set() {
  local f="$1" k="$2" v="$3"
  if [ ! -f "$f" ]; then
    printf '%s=%s\n' "$k" "$v" > "$f"
    return 0
  fi
  if grep -qE "^${k}=" "$f"; then
    # 用 | 当 sed 分隔符（口令是 hex，不会撞）；仍把值里的 & | \ 转义一遍防手填带进来
    local esc
    esc=$(printf '%s' "$v" | sed 's/[&|\\]/\\&/g')
    sed -i "s|^${k}=.*|${k}=${esc}|" "$f"
  else
    printf '%s=%s\n' "$k" "$v" >> "$f"
  fi
}

# 定中继口令。**两边必须一模一样**，否则 coturn 认证失败、通话静默退化成打洞
# （同 WiFi 能通、跨网就断，最难查的那类故障）。
# 以共享目录里的 turn.env 为准（它是持久的、也是服务端读的那份）：
#   · turn.env 里已有像样的值     -> 用它
#   · 它是空的/还是公开默认值     -> 用 .env 里已有的像样的值，或新生成一个，并回写 turn.env
xiaozhi_turn_pass_resolve() {
  local turn_env="$SHARE_DIR/data/turn.env"
  local from_turn_env="" from_dotenv="$1" pass=""
  [ -f "$turn_env" ] && from_turn_env=$(grep -E '^TURN_CREDENTIAL=' "$turn_env" | tail -1 | cut -d= -f2-)

  if ! xiaozhi_turn_pass_weak "$from_turn_env"; then
    pass="$from_turn_env"
  elif ! xiaozhi_turn_pass_weak "$from_dotenv"; then
    pass="$from_dotenv"
  else
    pass=$(xiaozhi_gen_secret)
    echo "[$APPNAME] 生成新的中继口令（原值为空或仍是公开默认值）"
  fi

  # 回写 turn.env：只改这两行，别的（尤其 Cloudflare 凭据）一个字都不碰
  xiaozhi_turn_env_set "$turn_env" "TURN_USERNAME" "${TURN_USER:-xiaozhi}"
  xiaozhi_turn_env_set "$turn_env" "TURN_CREDENTIAL" "$pass"
  echo "$pass"
}

# 写 docker/.env（保留已有密钥：升级不踢全员重新登录）
xiaozhi_env() {
  local ENV_FILE="${TRIM_APPDEST}/docker/.env"
  [ -z "$TRIM_APPDEST" ] && ENV_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/docker/.env"
  mkdir -p "$(dirname "$ENV_FILE")"

  local SECRET=""
  local OLD_IP=""
  # Cloudflare TURN 的 key 是用户自己去控制台申请后手填进 .env 的，
  # 而下面这段是整份重写 .env —— 不显式接住就会被升级冲掉，务必保留。
  local OLD_CF_ID=""
  local OLD_CF_TOKEN=""
  local OLD_TURN_PASS=""
  if [ -f "$ENV_FILE" ]; then
    SECRET=$(grep -E '^JWT_SECRET=' "$ENV_FILE" | tail -1 | cut -d= -f2-)
    OLD_IP=$(grep -E '^TURN_EXTERNAL_IP=' "$ENV_FILE" | tail -1 | cut -d= -f2-)
    OLD_CF_ID=$(grep -E '^CF_TURN_KEY_ID=' "$ENV_FILE" | tail -1 | cut -d= -f2-)
    OLD_CF_TOKEN=$(grep -E '^CF_TURN_API_TOKEN=' "$ENV_FILE" | tail -1 | cut -d= -f2-)
    OLD_TURN_PASS=$(grep -E '^TURN_PASSWORD=' "$ENV_FILE" | tail -1 | cut -d= -f2-)
  fi
  [ -z "$SECRET" ] && SECRET=$(xiaozhi_gen_secret)

  # 中继口令：首次安装生成、升级复用，并保证 .env 与 /data/turn.env 完全一致。
  # 这里把 turn.env 也一起管起来，是因为**服务端优先读 turn.env**：
  # 只改 .env 而不改 turn.env 的话，容器里下发给客户端的还是旧口令，
  # coturn 却用新口令 —— 表现为「中继配着但一通就断」，比直接不配更难查。
  local TURNPASS
  TURNPASS=$(xiaozhi_turn_pass_resolve "$OLD_TURN_PASS")

  # 公网 IP：每次安装/升级都重探（家宽基本是动态 IP，写死过几天就失效）。
  # 探测失败时沿用上次的值 —— 别把一份可能还能用的配置擦成空的。
  #
  # 重试 3 轮：安装早期网络/DNS 常常还没就绪，一次探测失败就会把
  # TURN_URLS 写成注释、容器起来后没有中继（2026-09-12 实际踩到，
  # 表现为 /api/call/ice 返回 turnConfigured:false 而 .env 里明明有值）。
  local PUBIP=""
  local OLD_IP_TRY="$OLD_IP"
  for round in 1 2 3; do
    for u in https://ipinfo.io/ip https://api.ipify.org https://ifconfig.me/ip; do
      PUBIP=$(curl -s -m 6 "$u" 2>/dev/null | tr -d '[:space:]')
      case "$PUBIP" in
        [0-9]*.[0-9]*.[0-9]*.[0-9]*) break ;;
        *) PUBIP="" ;;
      esac
    done
    [ -n "$PUBIP" ] && break
    [ "$round" -lt 3 ] && sleep 2
  done
  [ -z "$PUBIP" ] && PUBIP="$OLD_IP_TRY"

  local TURN_IP_LINE="# 未探测到公网 IP，TURN 中继仅内网可用"
  local TURN_URL_LINE="# TURN_URLS="
  if [ -n "$PUBIP" ]; then
    TURN_IP_LINE="TURN_EXTERNAL_IP=$PUBIP"
    # 同时下发 UDP 和 TCP 两条中继：
    #   - UDP 是首选（延迟低），但需要路由器映射 3478/udp + 49160-49200/udp
    #   - TCP 只需放通 3478/tcp 一个端口，适合"没有公网 IP、只能靠
    #     ZeroNews 等 TCP 隧道"的场景：隧道通一个口，外网通话就能走中继
    # 客户端 ICE 会自己挑能通的那条，不通的候选自动丢弃，不会互相干扰。
    TURN_URL_LINE="TURN_URLS=turn:$PUBIP:3478?transport=udp,turn:$PUBIP:3478?transport=tcp"
  fi

  cat > "$ENV_FILE" <<EOF
# 由安装/升级回调自动生成，请勿手改
TRIM_APPDEST=$TRIM_APPDEST
XIAOZHI_DATA_DIR=$SHARE_DIR/data
JWT_SECRET=$SECRET

# ---- 方案一（推荐）：Cloudflare Realtime TURN ----
# 只用出站连接、走 443/TLS，**完全不需要端口映射**，免费额度 1TB/月。
# 家宽没有公网 IP 时这是最省事的通路。开通：
#   dash.cloudflare.com → Realtime → TURN keys 新建
#   拿到 KEY ID 与 scope 为 "Calls: Edit" 的 API Token 填到下面两行
# 填完执行：cd docker && docker compose up -d --force-recreate xiaozhi-im
CF_TURN_KEY_ID=$OLD_CF_ID
CF_TURN_API_TOKEN=$OLD_CF_TOKEN

# ---- 方案二：自建 coturn（延迟更低，但要让公网能打进来）----
# 写了地址不等于外网就能用，还要放通：
#   3478/udp + 3478/tcp（信令/分配）
#   49160-49200/udp（中继通道）
# 二选一：
#   A) 路由器端口映射（家宽有公网 IP 时最简单）
#   B) 支持 TCP/UDP 的内网穿透隧道
#      （注意：ZeroNews 免费版不支持 TCP/UDP 隧道，要付费档才行）
# 一条都没打通的话，跨网通话只能靠方案一；同网段通话不受影响。
$TURN_IP_LINE
$TURN_URL_LINE

# 中继账号口令：安装时生成、升级沿用，并同步写入 $SHARE_DIR/data/turn.env。
# coturn 与服务端都从这里取，两端必须一致 —— 只改一边会出现
# 「中继看着配好了，跨网通话却一连就断」这种极难查的故障。
TURN_USER=${TURN_USER:-xiaozhi}
TURN_PASSWORD=$TURNPASS
EOF
  echo "[$APPNAME] 已写入 $ENV_FILE (TURN_EXTERNAL_IP=${PUBIP:-无}, Cloudflare TURN=$([ -n "$OLD_CF_ID" ] && echo 已配置 || echo 未配置), 中继口令=$([ -n "$TURNPASS" ] && echo 已设置 || echo 缺失))"
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
#
# ⚠️ 必须 `--force-recreate`，不能用裸 `up -d`。
# 环境变量是在**容器创建时**烘进去的，而 fnOS 会在 init 与 callback 之间
# **自己跑一次 compose**——那一次用的是还没写好的 `.env`。等 callback 把
# `.env` 重写好时，容器已经存在，裸 `up -d` 判定"无变更"直接跳过，
# 于是容器里 TURN_URLS 永远是空的（2026-09-11、09-12 各踩一次）。
# 强制重建才能保证最终状态一定反映刚写好的 `.env`。
xiaozhi_up() {
  local D="${TRIM_APPDEST}/docker"
  [ -z "$TRIM_APPDEST" ] && D="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/docker"
  if [ -d "$D" ]; then
    cd "$D"
    # ⚠️ coturn 必须**一起**重建，不能只重建 $APPNAME。
    # fnOS 在 init 与 callback 之间会自己跑一次 compose，那一次 .env 还没写：
    # coturn 的环境变量（TURN_PASSWORD）在那一刻就被烘进容器了，之后
    # restart 策略反复重启也**一直是那一份空值** —— 表现为「装完没中继、
    # 日志里 coturn 一直报未设置口令」，而 .env 里明明有值。
    # 只有 force-recreate 才会用新 .env 重新创建容器。
    docker compose up -d --force-recreate "$APPNAME" coturn 2>&1 \
      || docker compose up -d --force-recreate "$APPNAME" 2>&1 \
      || docker compose up -d 2>&1 || true
  fi
}
