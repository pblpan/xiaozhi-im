#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""飞牛 SSH 公共层：连接 + 可靠的远程执行。

⚠️ 这里踩过的坑（值得写下来）：
    `sudo -S <cmd>` **不会把 <cmd> 交给 shell 解释**。也就是说
        sudo -S f=/a; k=b; if ...; then ...; fi
    会被前面的 shell 先按 `;` 拆开：sudo 只拿到 `f=/a`，后面的
    `k=b`、`if ...` 变成**普通用户**在跑（甚至报 command not found）。
    表现出来就是「命令看起来跑了、其实一半没跑，还不报错」——
    本次就是因此把中继口令写进 .env 的整段逻辑静默跳过了。

    正确做法：`sudo -S sh -c '<cmd>'`，并用 shlex.quote 做转义，
    让整段脚本原样交给远程 shell。下面 `run()` 就是干这个的。

用法：
    from fnos_ssh import connect, run, sudo_read, sudo_write
    c = connect()
    print(run(c, "docker ps --format '{{.Names}}'"))
"""
import os
import shlex
import sys

import paramiko

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fnos_auth import HOST, PASS, USER  # noqa: E402


def connect(timeout=20):
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=timeout)
    return c


NOISE = (
    "password for",                    # sudo 的提示
    "could not chdir to home directory",  # 飞牛登录用户没建家目录，纯噪音
    "[sudo]",
)


def real_err(err):
    """从 stderr 里滤掉固定噪音，只留下真正有意义的部分。"""
    lines = []
    for ln in (err or "").splitlines():
        low = ln.lower()
        if any(n in low for n in NOISE):
            continue
        if ln.strip():
            lines.append(ln.strip())
    return "\n".join(lines)


def run(c, cmd, sudo=True, timeout=300, check=False):
    """执行一条命令并返回 stdout（有实质 stderr 时附在末尾）。

    sudo=True 时走 `sudo -S sh -c '<cmd>'`，复合命令（; && if）都能正确执行。
    check=True 时，只要**滤掉噪音后**仍有 stderr 就抛错。
    """
    if sudo:
        full = "echo %s | sudo -S sh -c %s" % (shlex.quote(PASS), shlex.quote(cmd))
    else:
        full = cmd
    _, so, se = c.exec_command(full, timeout=timeout)
    out = so.read().decode("utf-8", "replace")
    err = se.read().decode("utf-8", "replace")
    err = real_err(err)
    if err:
        if check:
            raise RuntimeError("远程命令失败: %s\n%s" % (cmd, err[:500]))
        out = (out.rstrip() + "\n[stderr] " + err[:400]).strip()
    return out.strip()


def read_file(c, path, sudo=True):
    """读远端文件文本（不存在返回 None）。"""
    out = run(c, "test -f %s && cat %s || echo __NOFILE__" % (shlex.quote(path), shlex.quote(path)),
              sudo=sudo)
    if out.strip() == "__NOFILE__" or out.strip().endswith("__NOFILE__"):
        return None
    return out


def put_file(c, local_path, remote_path, mode=None, backup=True, stamp=""):
    """把本地文件放到远端路径：sftp 到 /tmp -> sudo cp 就位（远端属主常常不是登录用户）。

    返回 (是否成功, 远端字节数)。
    """
    import hashlib
    name = hashlib.md5(remote_path.encode("utf-8")).hexdigest()[:8] + "_" + os.path.basename(remote_path)
    tmp = "/tmp/xz_push_" + name
    sftp = c.open_sftp()
    try:
        sftp.put(local_path, tmp)
    finally:
        sftp.close()
    size = os.path.getsize(local_path)

    if backup:
        stamp = stamp or "bak"
        run(c, "test -f %s && cp -p %s %s.bak.%s; echo ok"
            % (shlex.quote(remote_path), shlex.quote(remote_path),
               shlex.quote(remote_path), stamp))
    if mode is None:
        got = run(c, "stat -c '%%a' %s 2>/dev/null || true" % shlex.quote(remote_path)).strip()
        mode = got or ("755" if remote_path.endswith(".sh") else "644")
    # 一行搞定：cp 不会自己建父目录，先 mkdir -p
    run(c, "mkdir -p $(dirname %s) && cp %s %s && chmod %s %s"
        % (shlex.quote(remote_path), shlex.quote(tmp), shlex.quote(remote_path),
           shlex.quote(mode), shlex.quote(remote_path)), check=True)
    run(c, "rm -f %s" % shlex.quote(tmp))
    got = run(c, "stat -c '%%s' %s" % shlex.quote(remote_path)).strip()
    return (got == str(size)), got
