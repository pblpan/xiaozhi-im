#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把 frps 一键部署到公网 VPS（白手起家「小智中转站」）。

凭据从 deploy/.vps.env 读取（gitignore，绝不入库）：
    VPS_HOST=公网IP
    VPS_PORT=22
    VPS_USER=root
    VPS_PASS=root密码
    FRP_TOKEN=<32位hex>

用法：python deploy/_vps_deploy_frps.py
流程：paramiko 连接 -> 上传 vps_frps_setup.sh -> 远程执行 -> 断言 frps active
      -> 本机 TCP 探测公网 7000 端口（穿透服务端对外可达才算真通）。
"""
import os
import socket
import sys
import time

import paramiko

HERE = os.path.dirname(os.path.abspath(__file__))
ENV_PATH = os.path.join(HERE, ".vps.env")
SETUP_SH = os.path.join(HERE, "vps_frps_setup.sh")


def load_env():
    env = {}
    with open(ENV_PATH, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip()
    return env


def main():
    env = load_env()
    host = env.get("VPS_HOST", "").strip()
    port = int(env.get("VPS_PORT", "22"))
    user = env.get("VPS_USER", "root")
    pwd = env.get("VPS_PASS", "")
    token = env.get("FRP_TOKEN", "")
    if not host or not pwd or not token:
        print("❌ .vps.env 缺 VPS_HOST / VPS_PASS / FRP_TOKEN")
        sys.exit(1)

    print(f"==> 连接 {user}@{host}:{port} ...")
    cli = paramiko.SSHClient()
    cli.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    cli.connect(host, port=port, username=user, password=pwd, timeout=25,
                allow_agent=False, look_for_keys=False)
    print("✅ SSH 登录成功")

    sftp = cli.open_sftp()
    sftp.put(SETUP_SH, "/tmp/vps_frps_setup.sh")
    sftp.close()
    print("✅ setup 脚本已上传")

    cmd = f"FRP_TOKEN={token} bash /tmp/vps_frps_setup.sh 2>&1"
    stdin, stdout, stderr = cli.exec_command(cmd, timeout=600)
    out = stdout.read().decode("utf-8", "replace")
    rc = stdout.channel.recv_exit_status()
    print(out)
    if rc != 0:
        print(f"❌ 远程执行失败（rc={rc}）")
        cli.close()
        sys.exit(1)
    cli.close()

    print("==> 本机侧公网探测 7000 端口（3 次尝试）")
    for i in range(3):
        try:
            with socket.create_connection((host, 7000), timeout=8):
                print(f"✅ 公网 {host}:7000 可达 —— frps 对外监听确认")
                print("\n🎉 部署完成。下一步：更新飞牛 frpc 的 serverAddr 指向此 IP。")
                return
        except OSError as e:
            print(f"  第{i+1}次: {e}，5 秒后重试...")
            time.sleep(5)
    print("❌ 公网 7000 不可达 —— 检查平台防火墙/安全组")
    sys.exit(1)


if __name__ == "__main__":
    main()
