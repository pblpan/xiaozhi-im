#!/usr/bin/env bash
# pubspec.yaml 的版本 与 lib/core/app_version.dart 的 kAppVersion 必须一致。
#
# 🔴 为什么需要这个闸门（2026-09-25 加）：
#    这两处不一致**不会让任何东西报错**，但后果是"看着没事、实际发错版" ——
#      · 界面上显示的版本号是错的（客户报版本时对不上）；
#      · "要不要升级"的比对读的也是 kAppVersion。
#    原来只有 verify_ios.py 里有这么一条断言，而它**没有任何流程会调用**
#    （既不进 CI、也不在打包脚本里），等于没有。app_version.dart 的注释还写着
#    "verify_release.py 会主动拦住漏改" —— 连文件名都是错的。
#    从 0.18.0 起接进 CI 的 test job：改完 pubspec 忘了改 app_version.dart 就会红。
#
# ⚠️ 另外两处**不需要**同步（老文档写的"三处同步"把结果当成了原因）：
#    android/local.properties 的 flutter.versionName/versionCode 是 **Flutter 工具
#    每次构建从 pubspec 覆写出来的派生物**，而且它 .gitignore 了、CI 根本看不到。
#    改它没有任何作用。产物名由 pack_win.py 从 pubspec.yaml 读。
#
# 用法：bash tools/check_version_sync.sh [client目录]
#   退出码：0 一致 / 1 不一致 / 2 判据本身读不出来（文件结构变了）
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLIENT="${1:-$(cd "$HERE/.." && pwd)}"

PUB="$CLIENT/pubspec.yaml"
APPVER="$CLIENT/lib/core/app_version.dart"

# 只用 grep/sed，不引 python —— CI 与本机都要能跑。
# `tr -d '\r'` 防 CRLF（本机 core.autocrlf=true，checkout 出来可能是 CRLF）。
pub="$(grep -m1 '^version:' "$PUB" 2>/dev/null |
  sed 's/^version:[[:space:]]*//' | cut -d+ -f1 | tr -d '\r')"
app="$(grep -m1 -oE "kAppVersion[[:space:]]*=[[:space:]]*'[^']+'" "$APPVER" 2>/dev/null |
  sed "s/.*'\(.*\)'.*/\1/" | tr -d '\r')"

echo "pubspec.yaml      : ${pub:-<读不到>}"
echo "app_version.dart  : ${app:-<读不到>}"

# ⚠️ "读不到"和"不一致"必须分开报：前者是**判据本身失效**（文件结构变了），
#    后者才是真的漏改。混在一起会让人按错的方向查（这仓库吃过这类亏）。
if [ -z "$pub" ] || [ -z "$app" ]; then
  echo "❌ 有一段读不出来 —— 是文件结构变了，不是版本不一致；先修判据本身"
  exit 2
fi

if [ "$pub" != "$app" ]; then
  echo "❌ 版本不一致：pubspec=$pub，kAppVersion=$app"
  echo "   → 改 client/lib/core/app_version.dart 的 kAppVersion"
  exit 1
fi

echo "✅ 版本一致：$pub"
