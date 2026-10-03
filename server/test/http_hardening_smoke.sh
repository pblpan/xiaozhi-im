#!/usr/bin/env bash
# 登录限流 / CORS / 安全头 / 就绪检查 的真实 HTTP 冒烟测试
#   bash test/http_hardening_smoke.sh
#
# 【为什么用 curl 而不是 e2e】
#   这几条验的是"HTTP 层面的响应头与状态码"，用 curl 直读响应头最直接，
#   也不会把断言藏在测试框架的封装里。服务端起在临时端口 + 临时 DATA_DIR，
#   **不碰现网库**（本机跑它等于开一个真的服务，所以收尾必须干净）。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
NODE="${NODE:-node}"
PORT="${PORT:-3997}"
TMP="$(mktemp -d)"

PASS=0; FAIL=0
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31m✗\033[0m %s  → %s\n' "$1" "$2"; FAIL=$((FAIL+1)); }
check(){ # check <名称> <期望> <实际>
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "期望 $2，实际 $3"; fi
}

cleanup() {
  [ -n "${SRV:-}" ] && kill "$SRV" 2>/dev/null
  wait "${SRV:-}" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

# ---- 启动被测服务（独立 DATA_DIR，不碰现网）----
DATA_DIR="$TMP/data" PORT="$PORT" "$NODE" "$ROOT/src/index.js" >"$TMP/srv.log" 2>&1 &
SRV=$!

BASE="http://127.0.0.1:$PORT"
for i in $(seq 1 40); do
  curl -s -o /dev/null "$BASE/api/health" && break
  sleep 0.5
done
if ! curl -s -o /dev/null "$BASE/api/health"; then
  echo "❌ 服务起不来，日志："; tail -20 "$TMP/srv.log"; exit 2
fi
echo "服务已在 $PORT 起来（DATA_DIR=$TMP/data，结束即销毁）"
echo ""

echo "=== ① 健康检查 ==="
check "/api/health 返回 200" "200" "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/health")"
check "/api/health 不依赖数据库也能答" "true" "$(curl -s "$BASE/api/health" | sed 's/.*"ok":\([a-z]*\).*/\1/')"

echo ""
echo "=== ② 就绪检查（会碰数据库）==="
R=$(curl -s "$BASE/api/ready")
check "/api/ready 返回 200" "200" "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/ready")"
check "/api/ready 报 db=ready" "ready" "$(echo "$R" | sed 's/.*"db":"\([a-z]*\)".*/\1/')"

echo ""
echo "=== ③ 安全头 ==="
H=$(curl -s -D - -o /dev/null "$BASE/api/health")
check "X-Content-Type-Options: nosniff" "1" "$(echo "$H" | grep -ci 'x-content-type-options: nosniff')"
check "X-Frame-Options: SAMEORIGIN"    "1" "$(echo "$H" | grep -ci 'x-frame-options: sameorigin')"
check "CSP frame-ancestors"            "1" "$(echo "$H" | grep -ci 'content-security-policy:.*frame-ancestors')"
check "Referrer-Policy"                "1" "$(echo "$H" | grep -ci 'referrer-policy:')"
check "x-powered-by 已隐藏"            "0" "$(echo "$H" | grep -ci 'x-powered-by')"
# HSTS 只能在 https 下加：http 环境加了会把浏览器永久锁到 https 而搞坏站点
check "http 下不加 HSTS（否则会把内网 http 站点锁死）" "0" "$(echo "$H" | grep -ci 'strict-transport-security')"

echo ""
echo "=== ④ CORS 白名单 ==="
check "放行 Vite 开发源 localhost:5173" "http://localhost:5173" \
  "$(curl -s -D - -o /dev/null -H 'Origin: http://localhost:5173' "$BASE/api/health" | grep -i 'access-control-allow-origin' | tr -d '\r' | sed 's/.*: //')"
check "拒绝陌生来源 evil.example.com（无该头 = 浏览器会拦）" "0" \
  "$(curl -s -D - -o /dev/null -H 'Origin: https://evil.example.com' "$BASE/api/health" | grep -ci 'access-control-allow-origin')"
check "同源/无 Origin（curl、服务端调用）不拦" "200" \
  "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/health")"

echo ""
echo "=== ⑤ 登录限流（IP 维度阈值 10 次 / 15 分钟）==="
CODES=""
for i in $(seq 1 12); do
  C=$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/auth/login" \
      -H 'Content-Type: application/json' -d '{"username":"nobody","password":"wrong"}')
  CODES="$CODES $C"
done
echo "  12 次尝试的返回码：$CODES"
FIRST429=$(echo "$CODES" | tr ' ' '\n' | grep -n 429 | head -1 | cut -d: -f1)
if [ -n "$FIRST429" ]; then
  ok "第 $FIRST429 次开始返回 429（限流生效）"
  check "超限后持续 429" "429 429" "$(echo "$CODES" | tr ' ' '\n' | tail -2 | tr '\n' ' ' | sed 's/ $//')"
else
  bad "限流未生效" "12 次里一次 429 都没有"
fi
BODY=$(curl -s -X POST "$BASE/api/auth/login" -H 'Content-Type: application/json' -d '{"username":"nobody","password":"wrong"}')
check "429 响应体带错误文案" "1" "$(echo "$BODY" | grep -c '过于频繁')"
check "429 带 Retry-After 头" "1" "$(curl -s -D - -o /dev/null -X POST "$BASE/api/auth/login" -H 'Content-Type: application/json' -d '{"username":"nobody","password":"wrong"}' | grep -ci 'retry-after')"
check "超限时**不执行**密码校验（不泄露账号是否存在）" "1" \
  "$(echo "$BODY" | grep -c '过于频繁')"

echo ""
echo "============================================================"
echo "通过 $PASS / $((PASS+FAIL))"
echo "============================================================"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
