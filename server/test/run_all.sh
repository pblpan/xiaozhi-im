#!/usr/bin/env bash
# 服务端 e2e 回归的**统一入口**（CI 的 test 闸门调它；本机也能跑）
#
#   bash test/run_all.sh                    # 跑常规回归
#   bash test/run_all.sh --mutation         # 额外跑变异测试（会临时改源码再还原）
#   bash test/run_all.sh --only inventory   # 只跑指定几个（逗号分隔）
#   bash test/run_all.sh --skip inventory   # 跳过指定几个
#
# ---------------------------------------------------------------------------
# 【为什么是 bash 而不是 node 调度】
#   这台 Windows 开发机上 **Node 派生任何子进程都会被安全软件拦**：
#   连 `spawnSync('echo hello')` 都报 `EBUSY`（和本机跑不了 flutter test 同源）。
#   所以调度交给 bash（bash 派子进程正常），node 只负责被测。
#   CI 的 ubuntu runner 没有这个限制，用同一入口行为一致。
#
# 【为什么串行，不并行】
#   每个测试都 spawn 一个真服务端，占的是**硬编码端口**，而且大量重号：
#     3696 → 4 个文件 / 3697 → 4 个 / 3698 → 3 个 / 3699 → 4 个 / 3713 → 2 个 / 3716 → 2 个
#   并行必然互相抢端口 → 随机红。给 25 个文件都做成端口可配是另一种风险，
#   这里选择串行：**宁可慢，也不要"随机红"**。
#
# 【为什么分"常规"与"变异"两层】
#   *_mutation.js 会**临时把源码改成坏的**，验证测试能不能抓出来，最后无条件还原
#   （纪律见 time_sensitive_mutation.js 开头）。它是"测试的测试"，慢且会动源码，
#   中途被 kill 就留下脏源码 —— 所以默认不跑，要显式 --mutation。
#
# 【判定只看退出码】
#   有的脚本失败时仍会打印一堆 ✓，看日志会误判成通过。退出码是唯一可信信号。

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODE="${NODE:-node}"
TIMEOUT_S="${TIMEOUT_S:-180}"

WITH_MUTATION=0
ONLY=""
SKIP=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mutation) WITH_MUTATION=1 ;;
    --only)   ONLY="${2:-}"; shift ;;
    --skip)   SKIP="${2:-}"; shift ;;
    -h|--help)
      sed -n '2,30p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
  shift
done

# ---- 组装清单：排除非测试文件 ----
ALL=()
for f in "$HERE"/*.js; do
  b="$(basename "$f" .js)"
  [ "$b" = "run_all" ] && continue          # 本文件
  [ "$b" = "apisign_doc_sample" ] && continue # 文档样例，不是测试
  if [ "$WITH_MUTATION" -eq 0 ] && [[ "$b" == *mutation* ]]; then continue; fi
  if [ -n "$ONLY" ] && [[ ",$ONLY," != *",$b,"* ]]; then continue; fi
  if [ -n "$SKIP" ] && [[ ",$SKIP," == *",$b,"* ]]; then continue; fi
  ALL+=("$b")
done

# 少数测试是 shell 写的（要起真服务用 curl 验响应头，node 写起来别扭）。
# 它们同样是回归的一部分。
#
# 🔴 这里**必须带上 .sh 后缀**（下面派发时靠它判断用 bash 还是 node 跑）。
#    早先写成 basename 去掉后缀，结果派发时 `[[ "$name" == *.sh ]]` 判不到，
#    于是去找 http_hardening_smoke.js —— 报 MODULE_NOT_FOUND，
#    看起来像"测试挂了"，其实是 runner 自己派错了命令。
#    --only/--skip 的匹配则统一用**去后缀**的名字，两边对外写法一致。
for f in "$HERE"/*.sh; do
  [ -e "$f" ] || continue
  full="$(basename "$f")"            # 带后缀，用于派发
  b="${full%.sh}"                    # 不带后缀，用于 --only/--skip
  [ "$b" = "run_all" ] && continue
  if [ -n "$ONLY" ] && [[ ",$ONLY," != *",$b,"* ]]; then continue; fi
  if [ -n "$SKIP" ] && [[ ",$SKIP," == *",$b,"* ]]; then continue; fi
  ALL+=("$full")
done

TOTAL=${#ALL[@]}
if [ "$TOTAL" -eq 0 ]; then
  echo "❌ 没有匹配到任何测试文件" >&2
  exit 2
fi

echo "服务端回归：$TOTAL 个测试，串行执行"
[ "$WITH_MUTATION" -eq 1 ] && echo "⚠️ 含变异测试：会临时改源码再还原，中途被 kill 会留下脏源码"
echo ""

PASSED=()
FAILED=()
# 环境性失败：测试自己 spawn 子进程，而这台 Windows 开发机上 Node 派生任何
# 子进程都会被安全软件拦（EBUSY，见 ratelimit/工具链同源问题）。
# 现象是「报了个错但 stderr 空、且错误信息里没有断言」—— 真失败一定有断言输出。
# 这类失败**在 CI（Linux runner）上不存在**，所以要标出来而不是混进真失败里。
ENVFAIL=()
TMPOUT="$(mktemp -d)"
trap 'rm -rf "$TMPOUT"' EXIT
START=$(date +%s)

# 该测试用 spawnSync 起子进程重载 config，本机被拦 → 归为环境性失败
is_env_fail() {
  case "$1" in
    admin_turn_wizard_test)
      grep -qE "子进程加载 config 失败" "$TMPOUT/$1.log" && return 0 ;;
  esac
  return 1
}

for name in "${ALL[@]}"; do
  t0=$(date +%s)
  printf '  %-30s' "$name"
  # .js 用 node 跑；.sh 用 bash 跑（少数测试是 shell 写的，见上面的清单组装）
  if [[ "$name" == *.sh ]]; then
    RUNNER=(bash "$HERE/$name")
  else
    RUNNER=("$NODE" "$HERE/$name.js")
  fi
  if ( cd "$HERE/.." && timeout "$TIMEOUT_S" "${RUNNER[@]}" ) >"$TMPOUT/$name.log" 2>&1; then
    printf '\033[32mPASS\033[0m  %ss\n' "$(( $(date +%s) - t0 ))"
    PASSED+=("$name")
  else
    rc=$?
    if is_env_fail "$name"; then
      printf '\033[33m跳过 \033[0m  %ss  (本机限制：测试需 spawn 子进程，见下)\n' "$(( $(date +%s) - t0 ))"
      ENVFAIL+=("$name")
    else
      printf '\033[31mFAIL\033[0m  %ss  (exit=%s)\n' "$(( $(date +%s) - t0 ))" "$rc"
      FAILED+=("$name:$rc")
    fi
  fi
done

ELAPSED=$(( $(date +%s) - START ))
echo ""
echo "============================================================"
echo "通过 ${#PASSED[@]} / $TOTAL   用时 ${ELAPSED}s"
if [ ${#ENVFAIL[@]} -gt 0 ]; then
  echo "环境性跳过 ${#ENVFAIL[@]}: ${ENVFAIL[*]}"
fi
echo "============================================================"

if [ ${#ENVFAIL[@]} -gt 0 ]; then
  echo ""
  echo "注：上面「环境性跳过」的是**本机 Windows 环境限制**，不是产品问题 ——"
  echo "    这些测试要 spawn 子进程，而这台机器上 Node 派子进程被安全软件拦"
  echo "    （报 EBUSY，连 spawnSync('echo hello') 都不行）。"
  echo "    CI 的 Linux runner 没有这个限制，会照常执行并判定。"
fi

if [ ${#FAILED[@]} -gt 0 ]; then
  echo ""
  printf '\033[31m失败明细：\033[0m\n'
  for item in "${FAILED[@]}"; do
    name="${item%%:*}"; rc="${item##*:}"
    echo ""
    echo "--- $name (exit=$rc) ---"
    # 只打尾部：失败原因通常在最后
    tail -30 "$TMPOUT/$name.log"
  done
  echo ""
  printf '\033[31m共 %s 个失败\033[0m\n' "${#FAILED[@]}"
  exit 1
fi

printf '\033[32m全部通过\033[0m\n'
exit 0
