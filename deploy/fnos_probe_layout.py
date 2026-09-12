# -*- coding: utf-8 -*-
"""探查小智IM 在飞牛上的实际部署层级（热更新前必做）"""
import paramiko

# ⚠️ 凭据一律不进源码（本仓库是 Public）：从环境变量 FNOS_PASS
#    或 deploy/.fnos.env 读取，详见 deploy/fnos_auth.py
from fnos_auth import HOST, PASS, USER  # noqa: E402
SUDO = "echo '%s' | sudo -S " % PASS

CMDS = [
    ("appcenter/xiaozhi-im 顶层", "ls -la /vol1/@appcenter/xiaozhi-im/ 2>&1 | head -25"),
    ("src 层", "ls -la /vol1/@appcenter/xiaozhi-im/src/ 2>&1 | head -25"),
    ("src/src 层", "ls -la /vol1/@appcenter/xiaozhi-im/src/src/ 2>&1 | head -25"),
    ("容器列表", SUDO + "docker ps -a --format '{{.Names}} | {{.Status}} | {{.Ports}}' 2>&1 | grep -v '^\\[sudo\\]' | head -20"),
    ("容器挂载", SUDO + "docker inspect xiaozhi-im --format '{{json .Mounts}}' 2>&1 | grep -v '^\\[sudo\\]' | head -c 1400"),
    ("容器启动命令", SUDO + "docker inspect xiaozhi-im --format 'Cmd={{json .Config.Cmd}} Entry={{json .Config.Entrypoint}} WorkingDir={{.Config.WorkingDir}}' 2>&1 | grep -v '^\\[sudo\\]' | head -c 600"),
    ("容器内 /app", SUDO + "docker exec xiaozhi-im sh -c 'ls -la /app | head -20; echo \"--- /app/src ---\"; ls -la /app/src | head -25' 2>&1 | grep -v '^\\[sudo\\]' | head -60"),
]


def main():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15,
              look_for_keys=False, allow_agent=False)
    for title, cmd in CMDS:
        print("\n===== %s =====" % title)
        _in, _out, _err = c.exec_command(cmd, timeout=60)
        out = _out.read().decode("utf-8", "replace")
        err = _err.read().decode("utf-8", "replace")
        print(out.strip())
        if err.strip():
            print("[stderr] " + err.strip()[:300])
    c.close()


if __name__ == "__main__":
    main()
