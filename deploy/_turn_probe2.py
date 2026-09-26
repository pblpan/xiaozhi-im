#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""查清 xiaozhi-im-turn 这个容器到底是不是 compose 管的。

上一轮 _turn_probe.py 已经证明：.env 里 TURN_PASSWORD 长度 64（有值），
compose 也写了 `- TURN_PASSWORD=${TURN_PASSWORD:-}`，可容器启动脚本却说
「未设置 TURN_PASSWORD」。唯一自洽的解释是 —— **容器根本不是按这份 compose
起来的**（`docker inspect` 里 HostConfig.Mounts 是空的，compose 明明声明了两个
bind，只要是 compose 起的就不该是空）。

只读脚本，只做判断。
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from fnos_ssh import connect, run  # noqa: E402

CMDS = [
    ('容器是否被 compose 管理（看 label）',
     "docker inspect xiaozhi-im-turn --format '{{json .Config.Labels}}' "
     "| tr ',' '\\n' | grep -i -E 'com\\.docker\\.compose' | head -20 || echo '无 compose 标签'"),

    ('容器实际环境变量（含 TURN_*）',
     "docker inspect xiaozhi-im-turn --format '{{json .Config.Env}}' | tr ',' '\\n'"
     " | grep -i turn || echo '（环境变量里没有 TURN_*）'"),

    ('容器实际挂载',
     "docker inspect xiaozhi-im-turn --format '{{json .HostConfig.Mounts}}'"),

    ('容器实际启动命令 / 镜像',
     "docker inspect xiaozhi-im-turn --format 'Cmd={{json .Config.Cmd}}  "
     "Entrypoint={{json .Config.Entrypoint}}  Image={{.Config.Image}}'"),

    ('网络模式 / 端口映射',
     "docker inspect xiaozhi-im-turn --format 'NetworkMode={{.HostConfig.NetworkMode}}  "
     "PortBindings={{json .HostConfig.PortBindings}}'"),

    ('compose 项目里所有容器（看谁真在跑）',
     "docker ps -a --filter 'label=com.docker.compose.project=xiaozhi-im'"
     " --format '{{.Names}} | {{.Status}}'"),

    ('compose 文件声明了哪些服务',
     "grep -E '^[a-z_-]+:' /vol1/@appcenter/xiaozhi-im/docker/docker-compose.yaml"),

    ('compose 是否在别的目录被起过（找其它 compose 文件）',
     "find /vol1/@appcenter /vol4/@appcenter -maxdepth 3 -name 'docker-compose.y*ml' "
     "2>/dev/null || true"),
]


def main():
    c = connect()
    for title, cmd in CMDS:
        print('\n=== %s ===' % title)
        out = run(c, cmd)
        out = out.decode('utf-8', 'replace') if isinstance(out, bytes) else str(out)
        print(out.strip() if out.strip() else '(空)')


if __name__ == '__main__':
    raise SystemExit(main())
