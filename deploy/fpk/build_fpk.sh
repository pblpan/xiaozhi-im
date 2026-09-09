#!/usr/bin/env bash
# 把小智 IM 服务端打包成飞牛 fpk 安装包
# 用法：bash deploy/fpk/build_fpk.sh
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SERVER="$ROOT/server"
ADMIN="$ROOT/admin"
FPK="$ROOT/deploy/fpk"
OUT="$ROOT/deploy/xiaozhi-im.fpk"
TMP="$(mktemp -d)"

echo "[1/4] 构建管理后台 -> server/public"
( cd "$ADMIN" && npm install && npm run build )

echo "[2/4] 打包 server 为 app.tgz（排除 node_modules/data）"
mkdir -p "$TMP/app"
tar -C "$SERVER" -czf "$TMP/app.tgz" --exclude=node_modules --exclude=data .

echo "[3/4] 组装 fpk 目录"
cp "$FPK/manifest"        "$TMP/manifest"
cp "$FPK/app.tgz"         "$TMP/app.tgz"
mkdir -p "$TMP/cmd" "$TMP/config" "$TMP/ui"
cp "$FPK/cmd/start.sh"    "$TMP/cmd/start.sh"
cp "$FPK/config/app.yaml" "$TMP/config/app.yaml"
cp "$FPK/ui/index.html"   "$TMP/ui/index.html"
[ -f "$FPK/ICON.png" ] && cp "$FPK/ICON.png" "$TMP/ICON.png"

echo "[4/4] 生成 $OUT"
tar -C "$TMP" -czf "$OUT" .
rm -rf "$TMP"
echo "完成：将 $OUT 上传到飞牛应用中心 -> 设置 -> 手动安装即可。"
