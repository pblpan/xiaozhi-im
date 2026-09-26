#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""体检自建 coturn 的口令链路（只读，不改任何东西）。

2026-09-26 晚：线上 xiaozhi-im-turn 一直在 Restarting(1)，日志只有一句
「未设置 TURN_PASSWORD，拒绝以空口令启动」。按 .env 的注释，口令本该
"安装时生成、升级沿用，并同步写入 turn.env"，所以问题一定出在这条链上
某一环脱了节 —— 但只看一句报错是定位不到的，得把两端都摊开对表。

只读脚本：只打印键名和**值长度**，不打印口令本身。
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from fnos_ssh import connect, run  # noqa: E402

APPDEST = '/vol1/@appcenter/xiaozhi-im'
DATA = '/var/apps/xiaozhi-im/shares/xiaozhi-im/data'

CMDS = [
    ('docker/.env 里 TURN_* 各项的值长度',
     "grep -E '^TURN_' %s/docker/.env | while IFS='=' read -r k v; do"
     " printf '%%-22s 长度=%%s\\n' \"$k\" \"${#v}\"; done" % APPDEST),

    ('服务端 turn.env 全文（键+长度）',
     "test -f %s/turn.env && grep -E '^[A-Z_]+=' %s/turn.env | while IFS='=' "
     "read -r k v; do printf '%%-24s 长度=%%s\\n' \"$k\" \"${#v}\"; done"
     " || echo 'turn.env 不存在'" % (DATA, DATA)),

    ('compose coturn 服务的完整 environment',
     "sed -n '/^  coturn:/,$p' %s/docker/docker-compose.yaml" % APPDEST),

    ('coturn 容器最近一次启动日志（前 12 行）',
     'docker logs xiaozhi-im-turn 2>&1 | head -12'),

    ('宿主机 3478 是否有人监听',
     "ss -tlnup 2>/dev/null | grep -w 3478 || echo '3478/tcp 无人监听'"),
    ('宿主机 3478/udp 是否有人监听',
     "ss -ulnp 2>/dev/null | grep -w 3478 || echo '3478/udp 无人监听'"),
    ('中继端口段 49160 是否有人监听',
     "ss -ulnp 2>/dev/null | grep -E '49160|49200' || echo '中继端口段无人监听'"),
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
