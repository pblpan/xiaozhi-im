# -*- coding: utf-8 -*-
"""
把本地打好的 fpk 上传到飞牛 NAS 的「软件」目录，供应用中心手动安装/覆盖升级。

用法:
    python deploy/fnos_upload_fpk.py [本地 fpk 路径]

默认:
    本地  deploy/fpk-build/xiaozhi-im.fpk
    远端  /vol1/1000/软件/小智IM-飞牛服务器端-v<版本>.fpk

上传后会做 md5 校验（本地 vs 远端），并顺带打印当前已安装版本，便于确认
「是不是真的需要升级」。
"""
import hashlib
import os
import re
import sys

import paramiko

HOST = "192.168.31.44"
USER = "pblpan"
PASS = "Pbl15858505566."
SUDO = "echo '%s' | sudo -S " % PASS
REMOTE_DIR = "/vol1/1000/软件"
REMOTE_APP = "/vol1/@appcenter/xiaozhi-im"

_HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_LOCAL = os.path.join(_HERE, "fpk-build", "xiaozhi-im.fpk")


def md5(path):
    h = hashlib.md5()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def run(cli, cmd, timeout=120):
    stdin, stdout, stderr = cli.exec_command(cmd, timeout=timeout)
    out = stdout.read().decode("utf-8", "replace")
    err = stderr.read().decode("utf-8", "replace")
    code = stdout.channel.recv_exit_status()
    return code, out, err


def main():
    local = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_LOCAL
    local = os.path.abspath(local)
    if not os.path.isfile(local):
        print("ERROR: 本地文件不存在 ->", local)
        return 1

    # 从 manifest 里取版本号，决定远端文件名
    version = "0.0.0"
    try:
        import tarfile
        with tarfile.open(local) as tf:
            m = tf.extractfile("manifest")
            if m:
                txt = m.read().decode("utf-8", "replace")
                mt = re.search(r"^version\s*=\s*(\S+)", txt, re.M)
                if mt:
                    version = mt.group(1)
    except Exception as e:  # 取不到就用 unknown，不强求
        print("WARN: 读 manifest 版本失败:", e)

    remote_name = "小智IM-飞牛服务器端-v%s.fpk" % version
    remote_path = "%s/%s" % (REMOTE_DIR, remote_name)

    size = os.path.getsize(local)
    print("本地 : %s (%.2f MB)" % (local, size / 1048576.0))
    print("远端 : %s:%s" % (HOST, remote_path))

    cli = paramiko.SSHClient()
    cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    cli.connect(HOST, username=USER, password=PASS, timeout=20)
    try:
        # 1) 确保目录存在
        code, out, err = run(cli, "mkdir -p '%s' && ls -d '%s'" % (REMOTE_DIR, REMOTE_DIR))
        if code != 0:
            print("ERROR: 远端目录不可用:", err.strip() or out.strip())
            return 1

        # 2) 当前已安装版本（看宿主机上 app 的 package.json / manifest）
        code, out, _ = run(cli, "cat %s/manifest 2>/dev/null | grep -E '^version' || true" % REMOTE_APP)
        cur = (out or "").strip()
        print("当前已安装:", cur if cur else "(未知/未安装)")

        # 3) 上传
        sftp = cli.open_sftp()
        try:
            def _prog(done, total):
                if total and (done % (5 << 20) < (1 << 20) or done == total):
                    print("  上传 %6.1f / %.1f MB" % (done / 1048576.0, total / 1048576.0))
            sftp.put(local, remote_path, callback=_prog)
        finally:
            sftp.close()

        # 4) md5 校验
        lmd5 = md5(local)
        code, out, _ = run(cli, "md5sum '%s'" % remote_path, timeout=180)
        rmd5 = (out or "").split()[0] if out else ""
        print("本地 md5:", lmd5)
        print("远端 md5:", rmd5)
        print("校验结果:", "✅ 一致" if lmd5 == rmd5 else "❌ 不一致，请重传")
        if lmd5 != rmd5:
            return 1

        code, out, _ = run(cli, "ls -la '%s'" % remote_path)
        print(out.strip())
        print("\n下一步: 飞牛「应用中心 → 设置 → 手动安装」选择 %s 覆盖安装（数据保留）" % remote_name)
        return 0
    finally:
        cli.close()


if __name__ == "__main__":
    sys.exit(main())
