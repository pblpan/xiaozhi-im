#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把本地文件推到飞牛上的指定位置（先备份远端原件）。

为什么不用 scp：
    /vol1/@appcenter/... 属于 docker-<app> 用户，登录用户 pblpan 不在那个组里，
    直接写会 permission denied。所以走「先 sftp 到 /tmp，再 sudo cp 就位」这条路。

用法：
    python deploy/fnos_push.py deploy/coturn/entrypoint.sh /vol1/@appcenter/xiaozhi-im/docker/coturn/entrypoint.sh
    python deploy/fnos_push.py a.yaml b.yaml /remote/dir/            # 多文件 + 目标目录
    ... --mode 755        指定权限（默认沿用远端已有文件的权限）
    ... --no-backup       不备份（默认备份成 <名>.bak.<月日时分>）

推完不会自动重启任何服务 —— 需要重建容器的场景请自行执行
`docker compose up -d --force-recreate <服务>`（环境变量/挂载文件只在创建时生效）。
"""
import argparse
import os
import sys
from datetime import datetime

import paramiko

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fnos_auth import HOST, PASS, USER  # noqa: E402


def connect():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=20)
    return c


def run(c, cmd, timeout=180):
    _, so, se = c.exec_command("echo '%s' | sudo -S %s" % (PASS, cmd), timeout=timeout)
    out = so.read().decode("utf-8", "replace").strip()
    err = se.read().decode("utf-8", "replace").strip()
    if err and "password for" not in err.lower():
        out = (out + "\n[stderr] " + err[:300]).strip()
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sources", nargs="+", help="本地文件（最后一个参数是远端路径）")
    ap.add_argument("--mode", help="就位后的权限，如 755（默认沿用远端原权限）")
    ap.add_argument("--no-backup", action="store_true")
    a = ap.parse_args()

    if len(a.sources) < 2:
        print(__doc__)
        return 2
    *locals_, remote = a.sources

    missing = [p for p in locals_ if not os.path.isfile(p)]
    if missing:
        for p in missing:
            print("本地文件不存在: %s" % p)
        return 2

    c = connect()
    rc = 0
    stamp = datetime.now().strftime("%m%d%H%M")
    try:
        sftp = c.open_sftp()
        for lp in locals_:
            name = os.path.basename(lp)
            # 远端目标是目录时，落到目录里
            is_dir = run(c, "[ -d '%s' ] && echo dir || echo file" % remote).strip().endswith("dir")
            rp = (remote.rstrip("/") + "/" + name) if is_dir else remote
            tmp = "/tmp/xz_push_" + name

            sftp.put(lp, tmp)
            size = os.path.getsize(lp)
            print("上传 %s (%d 字节) -> %s" % (name, size, tmp))

            # 原权限（文件不存在时给个合理默认：脚本 755，其他 644）
            perm = a.mode
            if not perm:
                got = run(c, "stat -c '%%a' '%s' 2>/dev/null || true" % rp).strip()
                perm = got if got else ("755" if name.endswith(".sh") else "644")

            if not a.no_backup:
                run(c, "test -f '%s' && cp -p '%s' '%s.bak.%s' 2>/dev/null; echo ok"
                    % (rp, rp, rp, stamp))

            out = run(c, "mkdir -p \"$(dirname '%s')\" && cp '%s' '%s' && chmod %s '%s' "
                         "&& ls -la '%s'" % (rp, tmp, rp, perm, rp, rp))
            print("  " + out.replace("\n", "\n  "))
            run(c, "rm -f '%s'" % tmp)

            # 复核：字节数一致才算真的就位（cp 静默失败过）
            got = run(c, "stat -c '%%s' '%s'" % rp).strip()
            if got == str(size):
                print("  校验 ✓ %s 字节一致" % size)
            else:
                print("  校验 ✗ 本地 %d / 远端 %s" % (size, got))
                rc = 1
        sftp.close()
    finally:
        c.close()
    return rc


if __name__ == "__main__":
    sys.exit(main())
