# -*- coding: utf-8 -*-
"""
小智IM 服务端热更新（飞牛 fpk 部署）

关键层级（已实测）：
    宿主 /vol1/@appcenter/xiaozhi-im/src         -> 容器 /app
    宿主 /vol1/@appcenter/xiaozhi-im/src/src     -> 容器 /app/src        <== 服务端代码
    宿主 /vol1/@appcenter/xiaozhi-im/src/public  -> 容器 /app/public     <== 管理后台静态产物
启动命令是 `node src/index.js`，工作目录 /app。改代码必须落到 .../src/src/，
只放到 .../src/ 是不会生效的（这是最容易踩的坑）。

流程：本地全量上传到 /tmp 暂存 -> sudo 覆盖到目标 -> chown -> md5 校验 -> 重启容器
"""
import hashlib
import os
import sys
import paramiko

# ⚠️ 凭据一律不进源码（本仓库是 Public）：从环境变量 FNOS_PASS
#    或 deploy/.fnos.env 读取，详见 deploy/fnos_auth.py
from fnos_auth import HOST, PASS, USER  # noqa: E402
SUDO = "echo '%s' | sudo -S " % PASS

REMOTE_APP = "/vol1/@appcenter/xiaozhi-im"
REMOTE_SRC = REMOTE_APP + "/src/src"
REMOTE_PUBLIC = REMOTE_APP + "/src/public"
STAGE = "/tmp/xz-hotfix"
CONTAINER = "xiaozhi-im"

_HERE = os.path.dirname(os.path.abspath(__file__))
LOCAL_SRC = os.path.join(_HERE, "..", "server", "src")
LOCAL_PUBLIC = os.path.join(_HERE, "..", "server", "public")
# 宿主 .../src/package.json -> 容器 /app/package.json。
# 管理台顶栏与服务端版本号都读它（routes/admin.js: require('../../package.json')），
# 所以**每次涨版本都必须一起推**，否则界面显示的还是旧版本号。
LOCAL_PKG = os.path.join(_HERE, "..", "server", "package.json")
REMOTE_APP_SRC = REMOTE_APP + "/src"


def collect_src():
    """服务端 js：server/src/**/*.js（相对路径 -> 绝对路径）"""
    out = []
    for root, dirs, files in os.walk(LOCAL_SRC):
        dirs[:] = [d for d in dirs if d != "node_modules"]
        for f in files:
            if f.endswith(".js"):
                full = os.path.join(root, f)
                out.append((full, os.path.relpath(full, LOCAL_SRC).replace("\\", "/")))
    return sorted(out, key=lambda x: x[1])


def collect_public():
    """管理后台静态产物：server/public/**"""
    out = []
    if not os.path.isdir(LOCAL_PUBLIC):
        return out
    for root, _dirs, files in os.walk(LOCAL_PUBLIC):
        for f in files:
            full = os.path.join(root, f)
            out.append((full, os.path.relpath(full, LOCAL_PUBLIC).replace("\\", "/")))
    return sorted(out, key=lambda x: x[1])


def run(c, cmd, timeout=120, quiet=False):
    _in, _out, _err = c.exec_command(cmd, timeout=timeout)
    out = _out.read().decode("utf-8", "replace")
    err = _err.read().decode("utf-8", "replace")
    if not quiet:
        body = "\n".join(l for l in out.splitlines() if not l.startswith("[sudo]"))
        if body.strip():
            print(body.strip())
    return out, err


def md5_of(path):
    with open(path, "rb") as fh:
        return hashlib.md5(fh.read()).hexdigest()


def main():
    targets = [
        ("服务端代码", collect_src(), REMOTE_SRC, STAGE + "/src", "/app/src"),
        ("管理后台", collect_public(), REMOTE_PUBLIC, STAGE + "/public", "/app/public"),
        ("服务端元数据", [(LOCAL_PKG, "package.json")],
         REMOTE_APP_SRC, STAGE + "/pkg", "/app"),
    ]

    for name, files, _r, _s, _c in targets:
        print("== %s：本地 %d 个文件" % (name, len(files)))

    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15,
              look_for_keys=False, allow_agent=False)
    print("\n== SSH 已连接 %s" % HOST)

    run(c, "rm -rf %s && mkdir -p %s/src/routes %s/public" % (STAGE, STAGE, STAGE))

    sftp = c.open_sftp()

    def ensure_dir(path):
        parts = path.strip("/").split("/")
        cur = ""
        for p in parts:
            cur += "/" + p
            try:
                sftp.stat(cur)
            except IOError:
                sftp.mkdir(cur)

    for name, files, _r, stage_dir, _c in targets:
        print("\n-- 上传 %s" % name)
        for local, rel in files:
            remote = "%s/%s" % (stage_dir, rel)
            ensure_dir(os.path.dirname(remote))
            sftp.put(local, remote)
        print("   %d 个文件已上传" % len(files))
    sftp.close()

    # 覆盖到运行目录
    #
    # ⚠️ 这里必须**按 targets 通用处理**。曾经把这一步写死成"只 cp src 和 public"，
    # 于是后来新增的第三个目标（package.json）上传成功、却永远没被拷进运行目录，
    # md5 校验才暴露出 1 个不一致 —— 加目标时务必确认这段没被写死。
    print("\n== 覆盖到运行目录")
    for name, _files, remote_dir, stage_dir, _c in targets:
        run(c, SUDO + "mkdir -p %s" % remote_dir)
        if name == "管理后台":
            # assets 里带 hash 文件名，旧文件必须清掉否则越堆越多
            run(c, SUDO + "rm -rf %s/assets" % remote_dir)
        run(c, SUDO + "cp -rf %s/. %s/" % (stage_dir, remote_dir))
    run(c, SUDO + "chown -R docker-xiaozhi-im:docker-xiaozhi-im %s %s %s"
        % (REMOTE_SRC, REMOTE_PUBLIC, REMOTE_APP_SRC))
    run(c, "rm -rf %s" % STAGE)

    # 校验
    print("\n== 校验（容器内 md5 vs 本地）")
    bad = 0
    for name, files, _r, _s, cdir in targets:
        for local, rel in files:
            _o, _e = run(c, SUDO + "docker exec %s md5sum %s/%s 2>/dev/null | awk '{print $1}'"
                         % (CONTAINER, cdir, rel), quiet=True)
            remote = _o.strip().splitlines()[-1].strip() if _o.strip() else ""
            local_md5 = md5_of(local)
            if not remote or remote != local_md5:
                bad += 1
                print("   [差异] %s/%s local=%s remote=%s"
                      % (cdir, rel, local_md5[:10], remote[:10]))
        print("   %s 校验完成（累计不一致 %d）" % (name, bad))

    print("\n== 重启容器 %s" % CONTAINER)
    run(c, SUDO + "docker restart %s" % CONTAINER, timeout=180)
    c.close()

    print("\n== 完成，md5 不一致 %d 个" % bad)
    return 0 if bad == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
