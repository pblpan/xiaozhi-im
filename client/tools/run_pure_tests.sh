#!/usr/bin/env bash
# 在**包外**跑简易盘点的纯逻辑自测。
#
# ── 为什么不能在 client/ 里直接 dart run ──────────────────────
# 这台机器上 Dart 运行时的进程派生是坏的（`CreateFile failed 231` = ERROR_PIPE_BUSY）。
#   · `flutter test` 起不来（flutter_tools 还要先 `where aapt`，第一步就死）；
#   · `dart run tools/xxx.dart` 在**包内**也不行 —— 只要有 pubspec，dartdev 会去
#     跑 native assets 构建钩子，那一步要派生子进程，同样死。
#   · 但 `dart run <包外的裸脚本>` 是好的：没有 pubspec → 没有钩子 → 不派生。
# 所以这里把**不依赖 Flutter 的纯文件**复制到临时目录（保持 lib/core 的相对层级，
# 这样文件里的相对 import 一个字都不用改），在那边跑。
#
# ⚠️ 这是**补充**判据，不是正式判据。正式的是 CI 上的 `flutter test test/simple_*`，
#    那边还覆盖仓库层（要 sqflite）。
#
# 用法：bash tools/run_pure_tests.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT="$(cd "$HERE/.." && pwd)"
DART="${DART:-$CLIENT/../../tools/flutter/bin/dart.bat}"
# 🔴 2026-10-01 SDK 挪进了 flutter_sdk2/，旧 tools/flutter 没了 ——
#    这个脚本没跟着改，结果自测一直在报 "No such file or directory"
#    （看起来像"测试挂了"，其实是 runner 自己找不到 dart）。
#    与 tools/dart_typecheck/run.sh 的自动回退保持同一套写法。
if [ ! -e "$DART" ] && [ -e "$CLIENT/../../tools/flutter_sdk2/flutter/bin/dart.bat" ]; then
  DART="$CLIENT/../../tools/flutter_sdk2/flutter/bin/dart.bat"
fi

# 只有这几份是纯 Dart（零 Flutter / 零 IO）。加新的纯文件时记得也加到这里。
# 价签那一套（排版/模板/GBK 码表）也是零 Flutter 依赖的纯 Dart。
# 🔴 gbk_table 必须在：gbk.dart 与 gbk_encode.dart 都相对引用它，
#    漏了它自测连编译都过不去（报 URI 找不到，而不是断言失败）。
PURE_FILES=(
  inventory_rules.dart
  csv_fmt.dart
  qty_fmt.dart
  simple_rules.dart
  simple_export.dart
  gbk.dart
  gbk_encode.dart
  gbk_table.dart
  price_tag.dart
  price_tag_template.dart
)
PROBES=(
  simple_selftest.dart
  simple_export_selftest.dart
  price_tag_selftest.dart
)

# 🔴 用**每次唯一**的临时目录，不要 rm -rf 再建：
#    本机的安全策略会拦掉带盘符的 rm（`SAFE_DELETE_INVALID_PATH`），
#    一旦它静默失败，上一次跑剩的旧副本就会和这一次的 cp 混在一起 ——
#    而"源文件删了、临时目录里还留着"恰好会变成假绿。
TMP="${TMPDIR:-/tmp}/xz_pure_probe_$$"
mkdir -p "$TMP/lib/core" "$TMP/tools"

for f in "${PURE_FILES[@]}"; do
  if [ -f "$CLIENT/lib/core/$f" ]; then
    cp "$CLIENT/lib/core/$f" "$TMP/lib/core/$f"
  fi
done
for p in "${PROBES[@]}"; do
  cp "$CLIENT/tools/$p" "$TMP/tools/$p"
done

rc=0
for p in "${PROBES[@]}"; do
  echo "═══ $p ═══"
  # 包外没有 pubspec —— 这正是它能跑起来的原因，别在这里补一个。
  if ! "$DART" run "$TMP/tools/$p"; then
    rc=1
  fi
done

if [ "$rc" -ne 0 ]; then
  echo
  echo "❌ 纯逻辑自测有失败项（上面带 ✗ 的）"
fi
exit "$rc"
