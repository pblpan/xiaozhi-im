#!/bin/sh
# ============================================================
#  coturn 启动包装：自动探测公网 IP 再启动中继
#
#  家宽几乎都是动态公网 IP，而且让用户在路由器上把 IP 抄下来填进配置
#  也不现实（换 IP 就失效）。所以这里启动时自己问一次「我的公网出口是谁」，
#  写进 external-ip。coturn 只有拿到正确的公网地址，才能在 ICE 候选里
#  给出客户端真正能连上的中继地址。
# ============================================================
set -e

SRC=/etc/coturn/turnserver.conf
CONF=/tmp/turnserver.conf

MIN_PORT="${TURN_MIN_PORT:-49160}"
MAX_PORT="${TURN_MAX_PORT:-49200}"
REALM="${TURN_REALM:-xiaozhi.im}"
TUSER="${TURN_USER:-xiaozhi}"
TPASS="${TURN_PASSWORD:-xiaozhi-turn-2026}"

# ---- 探测公网出口 IP ----
# 飞牛安装脚本通常已经把结果放进 TURN_EXTERNAL_IP，这里只是兜底
# （镜像里不一定装了 curl，所以 wget 也一起试）。
detect_public_ip() {
  for url in https://ipinfo.io/ip https://api.ipify.org https://ifconfig.me/ip; do
    if command -v curl >/dev/null 2>&1; then
      ip=$(curl -s -m 6 "$url" 2>/dev/null | tr -d '[:space:]')
    elif command -v wget >/dev/null 2>&1; then
      ip=$(wget -q -T 6 -O - "$url" 2>/dev/null | tr -d '[:space:]')
    else
      ip=""
    fi
    case "$ip" in
      [0-9]*.[0-9]*.[0-9]*.[0-9]*) echo "$ip"; return 0 ;;
    esac
  done
  return 1
}

IP="${TURN_EXTERNAL_IP:-}"
if [ -z "$IP" ]; then
  IP=$(detect_public_ip || true)
fi

if [ -z "$IP" ]; then
  echo "[turn] ⚠ 探测公网 IP 失败，回退到 0.0.0.0（中继大概率不可用）。"
  echo "[turn]   请显式设置 TURN_EXTERNAL_IP 环境变量后重启此容器。"
  IP="0.0.0.0"
fi

# ---- 探测本机内网地址 ----
# 为什么要它：coturn 的 external-ip 支持「公网/内网」双地址写法。
# 写了内网地址后，两路通话都走本中继时（手机流量 <-> 家里设备都能接通话），
# coturn 发现对方候选其实就是自己的公网地址，会直接在内网侧投递，
# 不再绕出去打一圈 NAT 回环 —— 家用路由器基本都不支持回环，不写这一项
# 这种"双中继"通话仍会失败。
detect_lan_ip() {
  lan=$(ip route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)
  if [ -z "$lan" ]; then
    lan=$(ip -4 addr show scope global 2>/dev/null \
      | sed -n 's/.*inet \([0-9.]*\)\/.*/\1/p' \
      | grep -v '^172\.' | head -1)
  fi
  echo "$lan"
}

LAN_IP="${TURN_INTERNAL_IP:-}"
if [ -z "$LAN_IP" ]; then
  LAN_IP=$(detect_lan_ip || true)
fi

# 只有公网和内网确实不同、且都拿到时才用双地址写法
if [ -n "$LAN_IP" ] && [ "$LAN_IP" != "$IP" ] && [ "$IP" != "0.0.0.0" ]; then
  EXTERNAL_IP_VALUE="${IP}/${LAN_IP}"
else
  EXTERNAL_IP_VALUE="$IP"
fi

# ---- 渲染配置 ----
cp "$SRC" "$CONF"
sed -i "s|__EXTERNAL_IP__|${EXTERNAL_IP_VALUE}|g" "$CONF"
sed -i "s|__MIN_PORT__|${MIN_PORT}|g"  "$CONF"
sed -i "s|__MAX_PORT__|${MAX_PORT}|g"  "$CONF"
sed -i "s|__REALM__|${REALM}|g"        "$CONF"
sed -i "s|__TURN_USER__|${TUSER}|g"    "$CONF"
sed -i "s|__TURN_PASSWORD__|${TPASS}|g" "$CONF"

echo "[turn] ========================================"
echo "[turn] external-ip : ${EXTERNAL_IP_VALUE}"
echo "[turn] relay 端口  : ${MIN_PORT}-${MAX_PORT}/udp"
echo "[turn] 账号        : ${TUSER} / ******"
echo "[turn] ========================================"
if [ "$IP" = "0.0.0.0" ]; then
  echo "[turn] ⚠ 无公网地址，本容器只能供内网直连使用，外网通话仍需中继。"
fi

exec turnserver -c "$CONF"
