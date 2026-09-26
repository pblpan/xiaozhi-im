#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""定位「.env 有值、compose 却不认」的具体原因。

上一轮结论：容器是 compose 管的（label 齐全），但 TURN_PASSWORD / TURN_EXTERNAL_IP
进到容器后全是空，HostConfig.Mounts 也是 null —— 即 compose 起它时压根没吃 .env，
也没应用 YAML 里声明的 volumes。

本脚本用 `docker compose config`（只解析、不启动）把**最终生效配置**打出来，
再对照 .env 末尾字节，判断是不是「末行缺换行 → dotenv 丢最后一个键」这个坑。
只读脚本。
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from fnos_ssh import connect, run  # noqa: E402

D = '/vol1/@appcenter/xiaozhi-im/docker'

CMDS = [
    ('.env 末尾 3 字节（0a = 有换行；末行缺换行是经典坑）',
     "tail -c 3 %s/.env | od -c | head -3" % D),

    ('.env 行数 / 末行键名',
     "wc -l < %s/.env; echo '--- 末行 ---'; tail -1 %s/.env" % (D, D)),

    ('.env 权限与属主',
     "stat -c '%%a %%U:%%G  %%s 字节' %s/.env" % D),

    ('compose 解析后的 coturn 段（最终生效值）',
     "cd %s && docker compose config 2>&1 | sed -n '/^  coturn:/,$p'" % D),

    ('compose 认可的 .env 文件（会不会读的是别处）',
     "cd %s && docker compose config --services 2>&1 | head" % D),

    ('compose 版本',
     "cd %s && docker compose version 2>&1 | head -2" % D),
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
