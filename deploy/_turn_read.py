# -*- coding: utf-8 -*-
"""只读：把飞牛上 turn.env / docker/.env 的键名列出来（值一律打码）。

coturn 起不来的原因已经从日志里确认：TURN_PASSWORD 没设置，且 coturn 不再有
内置默认口令。要修就得知道现有 TURN_CREDENTIAL 是什么，再照抄进 docker/.env。
"""
import sys

sys.path.insert(0, __file__.rsplit('\\', 1)[0])
from fnos_ssh import connect, run

KEYS = 's/=.*/=/'


def mask(text):
    return ' '.join(l.split('=')[0] + '=' for l in text.splitlines() if l.strip())


def main():
    c = connect()
    print('-- /data/turn.env 的键 --')
    print(mask(run(c, 'cat /vol1/@appshare/xiaozhi-im/data/turn.env 2>&1')))
    print('-- docker/ 目录 --')
    print(run(c, 'ls -a /vol1/@appcenter/xiaozhi-im/docker/ 2>&1 | tr "\\n" " "').strip())
    print('-- docker/.env 的键 --')
    print(mask(run(c, 'cat /vol1/@appcenter/xiaozhi-im/docker/.env 2>&1')))
    print('-- 线上源码版本 --')
    print(run(c, "grep -m1 '\"version\"' /vol1/@appcenter/xiaozhi-im/src/package.json").strip())
    c.close()


if __name__ == '__main__':
    main()
