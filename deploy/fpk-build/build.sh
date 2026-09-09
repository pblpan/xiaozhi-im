#!/usr/bin/env bash
# ============================================================
#  小智IM 飞牛 fpk 打包脚本（在 Windows git-bash / Linux 均可跑）
#  用法: bash deploy/fpk-build/build.sh
#  产出: deploy/fpk-build/xiaozhi-im.fpk  （复制到桌面安装包即可）
#  原理:
#    1) 从 server/ 现拷源码 + 打包 node_modules.tar.gz 到 app/src
#    2) 生成/复用品牌图标 (需 python3 + pillow)
#    3) fnpack build 出 .fpk
# ============================================================
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

FN="deploy/fpk-build"
SRV="server"

PY=""
for cand in \
  "/c/Users/pblpa/.workbuddy/binaries/python/envs/default/Scripts/python.exe" \
  "$(which python3 2>/dev/null)" "$(which python 2>/dev/null)"; do
  [ -n "$cand" ] && [ -x "$cand" ] && PY="$cand" && break
done

# 0. fnpack 位置
FNPACK=""
for cand in \
  "/c/Users/pblpa/WorkBuddy/2026-09-03-19-27-29/fnpack.exe" \
  "/d/tmp/fnpack.exe" "$(which fnpack 2>/dev/null)"; do
  [ -n "$cand" ] && [ -f "$cand" ] && FNPACK="$cand" && break
done
[ -z "$FNPACK" ] && { echo "ERROR: fnpack.exe 未找到"; exit 1; }

echo "[1/4] 组装 app/src（server 源码 + node_modules.tar.gz）..."
rm -rf "$FN/app/src"
mkdir -p "$FN/app/src"
cp -r "$SRV/src"    "$FN/app/src/src"
cp -r "$SRV/public" "$FN/app/src/public"
cp "$SRV/package.json" "$SRV/package-lock.json" "$SRV/smoketest.js" "$FN/app/src/"
( cd "$SRV" && tar czf "../$FN/app/src/node_modules.tar.gz" node_modules )
echo "      src 就绪: $(du -sh "$FN/app/src" | cut -f1)"

echo "[2/4] 生成图标（若未生成）..."
if [ ! -f "$FN/ICON.PNG" ]; then
  "$PY" "$FN/gen_icons.py"
fi

echo "[3/4] fnpack build ..."
( cd "$FN" && "$FNPACK" build -d . )

echo "[4/4] 完成: $FN/xiaozhi-im.fpk"
ls -la "$FN/xiaozhi-im.fpk"
echo ""
echo "下一步: 把 xiaozhi-im.fpk 改名为 小智IM-飞牛安装包-v0.1.X.fpk 放到桌面安装包目录,"
echo "       并在飞牛 应用中心 → 手动安装 上传。"
