# -*- coding: utf-8 -*-
"""确认修复真的落到了远端 src 与容器内（避免"部署了但没落盘"这种假成功）。"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fnos_ssh import connect, run  # noqa: E402

SRC = '/vol1/@appcenter/xiaozhi-im/src/src'
checks = [
    ('admin.js 里有 mkdirsSafe 调用', "grep -c 'config.mkdirsSafe' %s/routes/admin.js" % SRC),
    ('admin.js 里没有 recursive mkdir', "grep -c 'recursive: true' %s/routes/admin.js || true" % SRC),
    ('config.js 有 mkdirsSafe 定义', "grep -c 'function mkdirsSafe' %s/config.js" % SRC),
    ('config.js 有 ensureFilesDir 定义', "grep -c 'function ensureFilesDir' %s/config.js" % SRC),
]

cli = connect()
for label, cmd in checks:
    out = run(cli, cmd)
    print('  %-34s -> %s' % (label, out.strip().splitlines()[-1] if out.strip() else '(空)'))

print('  --- 容器内 /app/src（bind mount，应与上面一致）---')
out = run(cli, "docker exec xiaozhi-im sh -c \"grep -c 'config.mkdirsSafe' /app/src/routes/admin.js; "
               "grep -c 'function mkdirsSafe' /app/src/config.js; "
               "grep -c 'function ensureFilesDir' /app/src/config.js\"")
print('  ' + ' / '.join(out.split()))
cli.close()
