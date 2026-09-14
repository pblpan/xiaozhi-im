#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
小智IM TURN 中继状态自检（只读，不改任何配置）

用法:
    python deploy/turn_status.py

它会依次检查：
  1. 容器是否在跑（服务端 / 中继）
  2. 服务端下发的 ICE 配置里有没有 TURN（turnConfigured 必须为 true）
  3. coturn 真正生效的配置（external-ip 双地址 / 端口范围 / 账号）
  4. 3478 的 UDP 与 TCP 监听
  5. 中继功能实测三连：UDP 分配 / TCP 分配 / 两端走中继互发

依赖: paramiko
飞牛地址/账号在下方常量里改（默认取本项目现场环境）。
"""
import os
import sys
import time

import paramiko

# ⚠️ 凭据一律不进源码（本仓库是 Public）：从环境变量 FNOS_PASS
#    或 deploy/.fnos.env 读取，详见 deploy/fnos_auth.py
from fnos_auth import HOST, PASS, USER  # noqa: E402
APPDIR = "/vol1/@appcenter/xiaozhi-im"
# 自建 coturn 的测试口令同样不入库。取值顺序：
#   1) 环境变量 TURN_PASSWORD（临时用）
#   2) 向**正在跑的 coturn 容器**要 —— 它环境变量里那个就是实际生效的值
# 为什么不再"猜一个默认值"：猜错了第 5 项会红着报「中继坏了」，而真相只是
# 自检自己用错口令。查故障最忌讳给错误信号。
TURN_PASSWORD = os.environ.get("TURN_PASSWORD", "")
TURN_USER = os.environ.get("TURN_USER", "xiaozhi")


def uargs():
    """turnutils_uclient 的认证参数；口令未知时返回空串（调用方会跳过）。"""
    if not TURN_PASSWORD:
        return ""
    return "-u %s -w %s -p 3478 -n 3 -m 1 127.0.0.1" % (TURN_USER, TURN_PASSWORD)


def resolve_turn_password(c):
    """从运行中的 coturn 容器里取实际生效的口令（取到就返回，取不到返回空）。"""
    global TURN_PASSWORD
    if TURN_PASSWORD:
        return TURN_PASSWORD
    _, so, _ = c.exec_command(
        "echo '%s' | sudo -S docker inspect xiaozhi-im-turn "
        "--format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null"
        " | grep '^TURN_PASSWORD=' | cut -d= -f2-" % PASS, timeout=60)
    val = so.read().decode("utf-8", "replace").strip()
    if val:
        TURN_PASSWORD = val
    return TURN_PASSWORD


def connect():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15)
    return c


def run(c, cmd, label, need_sudo=True, timeout=120):
    pre = ("echo '%s' | sudo -S " % PASS) if need_sudo else ""
    _, so, se = c.exec_command(pre + cmd, timeout=timeout)
    try:
        out = so.read().decode("utf-8", "replace").strip()
    except Exception as e:  # noqa: BLE001
        out = "<读取超时: %s>" % e
    err = se.read().decode("utf-8", "replace").strip()
    print("=" * 60)
    print(label)
    print("-" * 60)
    print(out if out else "(空)")
    low = err.lower()
    if err and "password for" not in low and "chdir" not in low:
        print("[stderr] %s" % err[:200])
    print()
    return out


def main():
    c = connect()

    print("小智IM TURN 中继自检  %s\n" % time.strftime("%Y-%m-%d %H:%M:%S"))

    pw = resolve_turn_password(c)
    if not pw:
        print("⚠ 拿不到 coturn 的口令（容器没跑 / 未配置 TURN_PASSWORD），"
              "第 5 项中继实测将无从执行。\n")

    run(c, "docker ps --format '{{.Names}}|{{.Status}}' | head -5", "1. 容器状态")

    run(c, "curl -s -m 10 http://127.0.0.1:3602/api/call/ice",
        "2. 服务端下发的 ICE 配置（turnConfigured 必须为 true）", need_sudo=False)

    run(c, "docker exec xiaozhi-im-turn sh -c "
           "'grep -E \"^(external-ip|min-port|max-port|user=|listening-port)\" /tmp/turnserver.conf'",
        "3. coturn 真正生效的配置（挂载模板是占位符，看这个 /tmp 渲染结果）")

    run(c, "echo -n '3478/udp 监听数: '; ss -lunp 2>/dev/null | grep -c ':3478'; "
           "echo -n '3478/tcp 监听数: '; ss -ltnp 2>/dev/null | grep -c ':3478'",
        "4. 3478 双协议监听")

    if pw:
        run(c, "docker exec xiaozhi-im-turn sh -c 'turnutils_uclient -T %s 2>&1 | tail -3'" % uargs(),
            "5a. 中继功能：UDP 分配（期望 lost 0%）")
        run(c, "docker exec xiaozhi-im-turn sh -c 'turnutils_uclient -T -t %s 2>&1 | tail -3'" % uargs(),
            "5b. 中继功能：TCP 分配（隧道方案靠它）")
        run(c, "docker exec xiaozhi-im-turn sh -c 'turnutils_uclient -T -y %s 2>&1 | tail -3'" % uargs(),
            "5c. 中继功能：两端走中继互发")
    else:
        print("=" * 60)
        print("5. 中继功能实测 —— 跳过（没拿到口令）")
        print("-" * 60)
        print("在 docker/.env 里补 TURN_PASSWORD=<强口令> 并重建容器后再跑。\n")

    # 口令打码：自检输出经常会贴进聊天/文档里，别把口令顺手带出去
    run(c, "grep -E '^TURN' %s/docker/.env | sed 's/^\\(TURN_PASSWORD=\\).*/\\1***/' "
           "|| echo '(未写入 TURN 配置)'" % APPDIR,
        "6. .env 里的 TURN 配置（口令已打码）")

    c.close()
    print("=" * 60)
    print("自检结束。第 2 项 turnConfigured 为 false 时，先补 .env 再重建容器；")
    print("第 5 项有丢包时看第 3 项的双地址与端口范围。")
    print("外网可达性无法在本机判定（本机与 NAS 同一出口），需用手机流量实测。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
