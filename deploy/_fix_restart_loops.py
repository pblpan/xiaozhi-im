#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""修复飞牛上两个重启循环的容器（2026-10-10）。

1) xiaozhi-im-turn（coturn）
   根因：容器是用**旧配置**创建的，env 里 TURN_PASSWORD 为空；
        而 /vol1/@appcenter/xiaozhi-im/docker/.env 里其实有口令。
        之前加固时改的 entrypoint 会拒绝空口令启动 → 无限重启。
   修法：把 .env 里的 TURN_EXTERNAL_IP/TURN_URLS 更新为当前真实出口 IP，
        然后 --force-recreate coturn，让容器拿到新的 env。

2) netops（网络运维工具箱）
   根因：/vol1/@appcenter/netops/src 是空目录，docker/docker-compose.yaml
        也不存在 —— 应用被半卸载（源码没了，容器还在按旧配置重启）。
   修法：把本地 netops.fpk 里的 app.tgz 传上去解包，恢复 src/ + docker/，
        再把旧数据目录里已经装好的 pylibs 拷回新的 data 目录（省去 pip），
        最后 compose up -d --force-recreate。

幂等：可重复执行。
"""
import os
import sys

import paramiko

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fnos_auth import HOST, USER, PASS  # noqa: E402

FPK = r"C:\Users\pblpa\WorkBuddy\2026-09-03-19-27-29\enhanced\netops.fpk"


def connect():
    cli = paramiko.SSHClient()
    cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    cli.connect(HOST, username=USER, password=PASS, timeout=20,
                allow_agent=False, look_for_keys=False)
    return cli


def sudo(cli, cmd, timeout=600, show=True):
    """用 sudo 执行一条 shell（密码通过 stdin 喂给 sudo -S）。"""
    full = f"echo '{PASS}' | sudo -S -p '' bash -c {_q(cmd)} 2>&1"
    _, out, _ = cli.exec_command(full, timeout=timeout)
    text = out.read().decode("utf-8", "replace")
    rc = out.channel.recv_exit_status()
    if show:
        print(f"$ {cmd}\n{text.rstrip()}\n[rc={rc}]")
    return text, rc


def _q(s):
    return "'" + s.replace("'", "'\"'\"'") + "'"


def fix_turn(cli):
    print("=" * 70)
    print("[1/2] 修复 xiaozhi-im-turn（coturn）")
    print("=" * 70)

    # 1) 当前出口 IP（容器里要用的"对外的那个地址"）
    text, _ = sudo(cli, "curl -s --max-time 15 https://api.ipify.org || curl -s --max-time 15 http://ifconfig.me/ip")
    ip = text.strip().splitlines()[-1].strip()
    print(f"  → 当前公网出口 IP：{ip}")

    envf = "/vol1/@appcenter/xiaozhi-im/docker/.env"
    sudo(cli, f"cp -a {envf} {envf}.bak.20261010 && echo backup-ok")

    # 2) 把过期的 TURN 地址换成当前出口 IP
    #    注意：TURN_EXTERNAL_IP 给 coturn 用；TURN_URLS 给服务端下发用。
    #    服务端实际读的是 /data/turn.env（优先级更高），那里也要同步改。
    sudo(cli, f"sed -i -E 's#^TURN_EXTERNAL_IP=.*#TURN_EXTERNAL_IP={ip}#' {envf}")
    sudo(cli, f"sed -i -E 's#^TURN_URLS=.*#TURN_URLS=turn:{ip}:3478?transport=udp,turn:{ip}:3478?transport=tcp#' {envf}")

    dataf = "/vol1/@appshare/xiaozhi-im/data/turn.env"
    sudo(cli, f"cp -a {dataf} {dataf}.bak.20261010 && echo databackup-ok")
    sudo(cli, f"sed -i -E 's#^TURN_URLS=.*#TURN_URLS=turn:{ip}:3478?transport=udp,turn:{ip}:3478?transport=tcp#' {dataf}")

    print(sudo(cli, f"grep -E '^TURN_(EXTERNAL_IP|URLS)' {envf}")[0].strip())
    print(sudo(cli, f"grep -E '^TURN_URLS' {dataf}")[0].strip())

    # 3) 重建 coturn —— 关键：让容器重新从 .env 读 TURN_PASSWORD
    out, rc = sudo(
        cli,
        "cd /vol1/@appcenter/xiaozhi-im/docker && "
        "docker compose up -d --force-recreate coturn",
        timeout=300,
    )
    return rc == 0


def fix_netops(cli):
    print("=" * 70)
    print("[2/2] 修复 netops（源码丢失导致的空转）")
    print("=" * 70)

    if not os.path.exists(FPK):
        print(f"  ✖ 找不到本地 fpk：{FPK}")
        return False

    # 1) 把 fpk 里的 app.tgz 抽出来传上去（比逐个文件上传快得多）
    import io
    import tarfile
    with tarfile.open(FPK) as t:
        app_tgz = t.extractfile("app.tgz").read()
    print(f"  → app.tgz {len(app_tgz)} 字节")

    sftp = cli.open_sftp()
    remote_tmp = "/tmp/netops_app.tgz"
    with sftp.open(remote_tmp, "wb") as fh:
        fh.write(app_tgz)
    sftp.close()
    print("  → 已上传到飞牛 /tmp/netops_app.tgz")

    # 2) 解包到应用目录（恢复 src/ 与 docker/）
    sudo(cli, "mkdir -p /vol1/@appcenter/netops && "
              "tar xzf /tmp/netops_app.tgz -C /vol1/@appcenter/netops && "
              "ls /vol1/@appcenter/netops")
    print(sudo(cli, "ls -la /vol1/@appcenter/netops/src | head -12")[0].strip())
    print(sudo(cli, "ls -la /vol1/@appcenter/netops/docker")[0].strip())

    # 3) 把 9-5 那次已经装好的 pylibs 拷回现在挂载的 data 目录
    #    （容器 CMD 里有 [ -f .deps_ok ] 判断，拷过去就不用再 pip 一遍 pysnmp 那些大包）
    out, _ = sudo(cli, "ls /var/apps/netops/shares/netops/data/ | head")
    if ".deps_ok" not in out:
        sudo(cli, "cp -a /vol1/@appshare/netops/data/pylibs /var/apps/netops/shares/netops/data/ 2>/dev/null; "
                  "touch /var/apps/netops/shares/netops/data/.deps_ok; echo pylibs-restored",
             timeout=300)

    # 4) 重建容器（compose 里用了 ${TRIM_APPDEST}，手动跑必须给）
    out, rc = sudo(
        cli,
        "cd /vol1/@appcenter/netops/docker && "
        "TRIM_APPDEST=/vol1/@appcenter/netops docker compose up -d --force-recreate",
        timeout=300,
    )
    return rc == 0


def main():
    cli = connect()
    try:
        ok1 = fix_turn(cli)
        ok2 = fix_netops(cli)
        print("=" * 70)
        sudo(cli, "docker ps -a --format 'table {{.Names}}|{{.Status}}'")
        print(f"turn 修复: {'OK' if ok1 else 'FAIL'} / netops 修复: {'OK' if ok2 else 'FAIL'}")
    finally:
        cli.close()


if __name__ == "__main__":
    main()
