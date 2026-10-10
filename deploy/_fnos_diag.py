#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""飞牛远程命令执行器（stderr 合并）。
用法：python deploy/_fnos_diag.py "<shell 命令>"
"""
import os
import sys

import paramiko

from fnos_auth import HOST, USER, PASS


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "uptime"
    cli = paramiko.SSHClient()
    cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    cli.connect(HOST, username=USER, password=PASS, timeout=20,
                allow_agent=False, look_for_keys=False)
    full = f"echo '{PASS}' | sudo -S -v && {cmd} 2>&1"
    _, stdout, _ = cli.exec_command(full, timeout=120)
    out = stdout.read().decode("utf-8", "replace")
    rc = stdout.channel.recv_exit_status()
    print(out)
    print(f"[rc={rc}]")
    cli.close()


if __name__ == "__main__":
    main()
