#!/usr/bin/env bash
# frps 服务端一键部署（Ubuntu 24.04，白手起家 VPS「小智中转站」）
# 用法：FRP_TOKEN=<hex> bash vps_frps_setup.sh
# 依据 skill「frp-fnos-deploy」第二节；本机商业机房优先 GitHub 直连二进制，
# 失败才回退 goproxy.cn 源码编译（三丰云受限网络路径）。
set -euo pipefail

FRP_TOKEN="${FRP_TOKEN:?需要 FRP_TOKEN 环境变量}"
FRP_VER="0.61.1"
PORTS=(7000 3601 3602 5000)

echo "==> [1/5] 架构检测"
ARCH=$(uname -m)
case "$ARCH" in
  x86_64) A=amd64 ;;
  aarch64) A=arm64 ;;
  *) echo "未知架构 $ARCH"; exit 1 ;;
esac
echo "    arch=$ARCH -> $A"

echo "==> [2/5] 安装 frps $FRP_VER"
BIN=""
if curl -fsSL --connect-timeout 15 -o /tmp/frp.tgz \
    "https://github.com/fatedier/frp/releases/download/v${FRP_VER}/frp_${FRP_VER}_linux_${A}.tar.gz"; then
  tar xzf /tmp/frp.tgz -C /tmp
  install -m 755 "/tmp/frp_${FRP_VER}_linux_${A}/frps" /usr/local/bin/frps
  BIN=/usr/local/bin/frps
else
  echo "    GitHub 直连失败，回退 goproxy.cn 源码编译（受限网络路径）"
  apt-get update -qq && apt-get install -y -qq golang-go >/dev/null
  rm -rf /tmp/frpsrc && mkdir -p /tmp/frpsrc
  curl -fsSL -o /tmp/frpsrc/frp.zip "https://goproxy.cn/github.com/fatedier/frp@v${FRP_VER}.zip"
  unzip -q /tmp/frpsrc/frp.zip -d /tmp/frpsrc
  SRC=$(find /tmp/frpsrc -maxdepth 2 -type d -name "frp@*" | head -1)
  (cd "$SRC" && GOPROXY=https://goproxy.cn,direct go build -o /usr/local/bin/frps ./cmd/frps)
  BIN=/usr/local/bin/frps
fi
"$BIN" --version

echo "==> [3/5] 写配置 /etc/frp/frps.toml"
mkdir -p /etc/frp
cat > /etc/frp/frps.toml <<EOF
bindPort = 7000
auth.token = "${FRP_TOKEN}"
EOF
chmod 600 /etc/frp/frps.toml

echo "==> [4/5] systemd 服务"
cat > /etc/systemd/system/frps.service <<EOF
[Unit]
Description=frp server (xiaozhi relay)
After=network.target

[Service]
ExecStart=${BIN} -c /etc/frp/frps.toml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now frps

echo "==> [5/5] 防火墙（ufw 仅在已激活时补规则，不强行启用）"
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
  for p in 22 "${PORTS[@]}"; do ufw allow "$p"/tcp >/dev/null; done
  echo "    ufw 已激活，放行: 22 ${PORTS[*]}"
else
  echo "    ufw 未激活，跳过（平台安全组当前为全开）"
fi

echo "==> 自检（断言式，失败即退出非 0）"
systemctl is-active --quiet frps || { echo "❌ frps 未运行"; exit 1; }
# enable --now 返回 ≠ 端口已 listen（竞态），循环等待最多 15 秒
OK7000=""
for i in $(seq 1 15); do
  if ss -tln | grep -q ":7000 "; then OK7000=1; break; fi
  sleep 1
done
[ -n "$OK7000" ] || { echo "❌ 15 秒内 7000 未监听"; journalctl -u frps --no-pager -n 20; exit 1; }
echo "✅ frps 部署完成：7000 监听中，token 已写入 /etc/frp/frps.toml"
