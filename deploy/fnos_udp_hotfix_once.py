# -*- coding: utf-8 -*-
"""一次性热修：给生产 compose 补 3616/udp 端口映射并重建容器。

背景：v0.11.0 新增 UDP 3616 局域网发现，fnos_hotfix.py 只推 src/public，
不动 docker/docker-compose.yaml —— 容器还是旧端口映射，发现服务静默失效。
跑完即弃，不放回常规流程（build.sh 打包时已含新 compose，重装 fpk 不需要本脚本）。
"""
import sys
from fnos_auth import HOST, PASS, USER  # noqa: E402

COMPOSE = "/vol1/@appcenter/xiaozhi-im/docker/docker-compose.yaml"


def main():
    import paramiko
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=15,
              look_for_keys=False, allow_agent=False)

    def run(cmd, timeout=180):
        _i, o, e = c.exec_command(cmd, timeout=timeout)
        out = o.read().decode("utf-8", "replace")
        err = e.read().decode("utf-8", "replace")
        return out, err

    # ① 看现状
    out, _ = run("grep -n '3616' %s || echo NO_3616" % COMPOSE)
    print("现状:", out.strip())
    if "NO_3616" not in out:
        print("已有 3616 映射，跳过修改")
    else:
        # ② 在 3602 端口行后插入 3616/udp（幂等：只在 3602 行存在且 3616 不存在时）
        cmd = (
            "echo '%s' | sudo -S sh -c \""
            "sed -i '/\\\"3602:3602\\\"/a\\"
            "      # 局域网发现（UDP 广播应答）：客户端首装时自动找到服务器\\\\n"
            "      - \\\"3616:3616/udp\\\"' %s && "
            "grep -n '3616' %s\""
        ) % (PASS, COMPOSE, COMPOSE)
        out, err = run(cmd)
        print("插入后:", out.strip(), err.strip())
        if "3616" not in out:
            print("插入失败，中止")
            c.close()
            sys.exit(1)

    # ③ 重建容器（compose 项目目录必须在 docker/ 下，让 .env 生效）
    out, err = run(
        "echo '%s' | sudo -S sh -c 'cd /vol1/@appcenter/xiaozhi-im/docker && "
        "docker compose up -d --force-recreate 2>&1'" % PASS, timeout=300)
    print("重建:", out.strip(), err.strip())

    # ④ 端口确认
    out, _ = run("echo '%s' | sudo -S docker port xiaozhi-im" % PASS)
    print("端口映射:", out.strip())
    c.close()


if __name__ == "__main__":
    main()
