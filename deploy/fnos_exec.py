#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""在飞牛 NAS 上跑命令（sudo），把 stdout/stderr 原样打回来。

为什么单独做一个小工具：
    排障时经常只想知道「远程那台现在到底是什么样」——看一个文件、查一次容器
    环境变量、确认挂载路径。每次现写一个 paramiko 脚本既慢又容易把密码写进
    源码（本仓库是 Public，历史上就出过这个事故）。

用法：
    python deploy/fnos_exec.py "cat /vol1/@appcenter/xiaozhi-im/docker/.env"
    python deploy/fnos_exec.py "docker ps" "docker inspect xiaozhi-im-turn" --no-sudo
    python deploy/fnos_exec.py -- mask "sed -n 's/^\\(SECRET=\\).*/\\1***/p' x.env"   # 输出打码

凭据来源见 deploy/fnos_auth.py（环境变量 FNOS_PASS 或 deploy/.fnos.env）。
"""
import argparse
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fnos_ssh import connect, run  # noqa: E402


def mask_secrets(text):
    """把明显的机密值打码 —— 便于把排障输出直接贴出来。"""
    pats = [
        (r'(?i)(PASS(WORD)?\s*[=:]\s*)(\S+)', r'\1***'),
        (r'(?i)(SECRET\s*[=:]\s*)(\S+)', r'\1***'),
        (r'(?i)(TOKEN\s*[=:]\s*)(\S+)', r'\1***'),
        (r'(?i)(CREDENTIAL\s*[=:]\s*)(\S+)', r'\1***'),
        (r'(?i)(_KEY(_ID)?\s*[=:]\s*)(\S+)', r'\1***'),
    ]
    for p, r in pats:
        text = re.sub(p, r, text)
    return text


def main():
    ap = argparse.ArgumentParser(description='在飞牛 NAS 上执行命令')
    ap.add_argument('commands', nargs='+', help='要执行的命令（可多条）')
    ap.add_argument('--no-sudo', action='store_true', help='不加 sudo')
    ap.add_argument('--mask', action='store_true', help='机密值打码后再输出')
    a = ap.parse_args()

    client = connect()
    try:
        for i, cmd in enumerate(a.commands):
            if len(a.commands) > 1:
                print('=' * 64)
                print('$ %s' % cmd)
                print('-' * 64)
            out = run(client, cmd, sudo=not a.no_sudo)
            if a.mask:
                out = mask_secrets(out)
            sys.stdout.write(out if out.strip() else '(无输出)\n')
            if len(a.commands) > 1:
                print()
    finally:
        client.close()
    return 0


if __name__ == '__main__':
    sys.exit(main())
