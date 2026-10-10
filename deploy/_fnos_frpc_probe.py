#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""探查飞牛上 frpc 现状：容器、配置文件内容。只读，不改任何东西。"""
import sys

import paramiko

from fnos_auth import HOST, USER, PASS


def run(cli, cmd, timeout=60):
    _, stdout, _ = cli.exec_command(cmd, timeout=timeout)
    out = stdout.read().decode("utf-8", "replace")
    rc = stdout.channel.recv_exit_status()
    return rc, out


def main():
    cli = paramiko.SSHClient()
    cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    cli.connect(HOST, username=USER, password=PASS, timeout=20,
                allow_agent=False, look_for_keys=False)

    rc, out = run(cli, f"echo '{PASS}' | sudo -S docker ps -a 2>/dev/null | grep -i frp")
    print("== docker frp 容器 ==\n", out or "(无)")

    rc, out = run(cli, "ls -la /vol1/system/frpc/ 2>/dev/null || echo NO_DIR")
    print("== /vol1/system/frpc/ ==\n", out)

    rc, out = run(cli, "sudo -n cat /vol1/system/frpc/frpc.toml 2>/dev/null || "
                       f"echo '{PASS}' | sudo -S cat /vol1/system/frpc/frpc.toml 2>/dev/null || echo NO_FILE")
    print("== frpc.toml 内容 ==\n", out)

    cli.close()


if __name__ == "__main__":
    sys.exit(main())
