#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把飞牛 frpc 切到新公网 VPS（白手起家 185.242.233.140）并拉起容器。

- 旧配置先备份为 frpc.toml.bak-<日期>
- token 从 deploy/.vps.env 的 FRP_TOKEN 读取（不硬编码）
- 容器按 skill「frp-fnos-deploy」三坑：挂载 /frp/frpc.toml、--network host、--restart unless-stopped
- 断言：docker logs 必须出现 login success + 三个 proxy success
"""
import base64
import json
import os
import time

import paramiko

from fnos_auth import HOST, USER, PASS

HERE = os.path.dirname(os.path.abspath(__file__))
CONF = "/vol1/system/frpc/frpc.toml"
IMG = "stilleshan/frpc:0.61.1"

# token 从 .vps.env 读
with open(os.path.join(HERE, ".vps.env"), encoding="utf-8") as f:
    FRP_TOKEN = ""
    for line in f:
        if line.startswith("FRP_TOKEN="):
            FRP_TOKEN = line.split("=", 1)[1].strip()
assert FRP_TOKEN, "FRP_TOKEN 缺失"

NEW_CONF = {
    "serverAddr": "185.242.233.140",
    "serverPort": 7000,
    "auth": {"token": FRP_TOKEN},
    "proxies": [
        {"name": "factory", "type": "tcp", "localIP": "127.0.0.1", "localPort": 3601, "remotePort": 3601},
        {"name": "xiaozhi", "type": "tcp", "localIP": "127.0.0.1", "localPort": 3602, "remotePort": 3602},
        {"name": "netops", "type": "tcp", "localIP": "127.0.0.1", "localPort": 5000, "remotePort": 5000},
    ],
}


def run(cli, cmd, timeout=180):
    _, stdout, _ = cli.exec_command(cmd, timeout=timeout)
    out = stdout.read().decode("utf-8", "replace")
    rc = stdout.channel.recv_exit_status()
    return rc, out


def main():
    payload = base64.b64encode(
        json.dumps(NEW_CONF, ensure_ascii=False).encode()).decode()

    cli = paramiko.SSHClient()
    cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    cli.connect(HOST, username=USER, password=PASS, timeout=20,
                allow_agent=False, look_for_keys=False)

    def sudo(cmd):
        return f"echo '{PASS}' | sudo -S {cmd}"

    # 0. sudo 凭据跨 paramiko exec_command 会话不可靠（无 tty ticket 隔离），
    #    所以每条特权命令都必须自带 sudo -S 喂密码 —— 下方 sudo() 已统一，
    #    唯独「写配置」因为 stdin 要传数据流，改用 bash -c 包裹（见第 2 步）。

    # 1. 备份
    rc, out = run(cli, sudo(f"cp {CONF} {CONF}.bak-$(date +%m%d%H%M) && ls -la /vol1/system/frpc/"))
    print("== 备份 ==\n", out)
    if rc != 0:
        print("❌ 备份失败"); cli.close(); raise SystemExit(1)

    # 2. 写新配置：sudo -S 吃密码、bash -c 内部写文件，密码与数据流不冲突（一条命令搞定）
    rc, out = run(cli, f"echo '{PASS}' | sudo -S bash -c "
                       f"'echo {payload} | base64 -d > {CONF} && cat {CONF}' 2>/dev/null")
    print("== 新配置 ==\n", out)
    if '"serverAddr": "185.242.233.140"' not in out:
        print("❌ 新配置写入失败"); cli.close(); raise SystemExit(1)

    # 3. 镜像不在就拉
    rc, out = run(cli, f"sudo docker images | grep -q stilleshan/frpc || sudo docker pull {IMG}", timeout=300)
    print("== 镜像 ==\n", out or "已存在")

    # 4. 重建容器（rm 和 run 都要 root；stderr 合并便于排错）
    rc, out = run(cli, f"echo '{PASS}' | sudo -S bash -c "
                       f"'docker rm -f frpc 2>/dev/null; "
                       f"docker run -d --name frpc --network host --restart unless-stopped "
                       f"-v {CONF}:/frp/frpc.toml:ro {IMG}' 2>&1")
    print("== 启动 ==\n", out)
    if rc != 0:
        print("❌ 容器启动失败"); cli.close(); raise SystemExit(1)

    # 5. 日志断言（最多等 20 秒）
    ok_login = ok_proxies = False
    for _ in range(10):
        time.sleep(2)
        rc, out = run(cli, sudo("docker logs --tail 40 frpc 2>&1"))
        ok_login = "login to server success" in out
        ok_proxies = out.count("start proxy success") >= 3
        if ok_login and ok_proxies:
            break
    print("== frpc 日志 ==\n", out)
    if not (ok_login and ok_proxies):
        print("❌ frpc 未注册成功（login=%s proxies=3? %s）" % (ok_login, ok_proxies))
        cli.close(); raise SystemExit(1)

    print("✅ frpc 已连上新 VPS 且三个代理全部注册成功")
    cli.close()


if __name__ == "__main__":
    main()
