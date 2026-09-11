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
import sys
import time

import paramiko

HOST = "192.168.31.44"
USER = "pblpan"
PASS = "Pbl15858505566."
APPDIR = "/vol1/@appcenter/xiaozhi-im"
UARGS = "-u xiaozhi -w xiaozhi-turn-2026 -p 3478 -n 3 -m 1 127.0.0.1"


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

    run(c, "docker ps --format '{{.Names}}|{{.Status}}' | head -5", "1. 容器状态")

    run(c, "curl -s -m 10 http://127.0.0.1:3602/api/call/ice",
        "2. 服务端下发的 ICE 配置（turnConfigured 必须为 true）", need_sudo=False)

    run(c, "docker exec xiaozhi-im-turn sh -c "
           "'grep -E \"^(external-ip|min-port|max-port|user=|listening-port)\" /tmp/turnserver.conf'",
        "3. coturn 真正生效的配置（挂载模板是占位符，看这个 /tmp 渲染结果）")

    run(c, "echo -n '3478/udp 监听数: '; ss -lunp 2>/dev/null | grep -c ':3478'; "
           "echo -n '3478/tcp 监听数: '; ss -ltnp 2>/dev/null | grep -c ':3478'",
        "4. 3478 双协议监听")

    run(c, "docker exec xiaozhi-im-turn sh -c 'turnutils_uclient -T %s 2>&1 | tail -3'" % UARGS,
        "5a. 中继功能：UDP 分配（期望 lost 0%）")
    run(c, "docker exec xiaozhi-im-turn sh -c 'turnutils_uclient -T -t %s 2>&1 | tail -3'" % UARGS,
        "5b. 中继功能：TCP 分配（隧道方案靠它）")
    run(c, "docker exec xiaozhi-im-turn sh -c 'turnutils_uclient -T -y %s 2>&1 | tail -3'" % UARGS,
        "5c. 中继功能：两端走中继互发")

    run(c, "grep -E '^TURN' %s/docker/.env || echo '(未写入 TURN 配置)'" % APPDIR,
        "6. .env 里的 TURN 配置")

    c.close()
    print("=" * 60)
    print("自检结束。第 2 项 turnConfigured 为 false 时，先补 .env 再重建容器；")
    print("第 5 项有丢包时看第 3 项的双地址与端口范围。")
    print("外网可达性无法在本机判定（本机与 NAS 同一出口），需用手机流量实测。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
