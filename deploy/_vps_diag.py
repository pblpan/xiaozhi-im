#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""VPS 远程命令执行器（复用 .vps.env 凭据）。
用法：python deploy/_vps_diag.py "<shell 命令>"
"""
import os
import sys

import paramiko

HERE = os.path.dirname(os.path.abspath(__file__))


def load_env():
    env = {}
    with open(os.path.join(HERE, ".vps.env"), encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()
    return env


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "uptime"
    env = load_env()
    cli = paramiko.SSHClient()
    cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    cli.connect(env["VPS_HOST"], int(env.get("VPS_PORT", "22")),
                env.get("VPS_USER", "root"), env["VPS_PASS"], timeout=25,
                allow_agent=False, look_for_keys=False)
    _, stdout, _ = cli.exec_command(cmd, timeout=120)
    out = stdout.read().decode("utf-8", "replace")
    rc = stdout.channel.recv_exit_status()
    print(out)
    print(f"[rc={rc}]")
    cli.close()


if __name__ == "__main__":
    main()
