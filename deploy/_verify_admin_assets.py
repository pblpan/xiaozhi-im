#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""确认线上管理台 index.html 引用的 bundle 真能取到（200），且是新哈希。"""
import os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from fnos_ssh import connect, run

REMOTE_ROOT = '/vol1/@appcenter/xiaozhi-im/src'

c = connect()
html = run(c, 'cat %s/public/index.html' % REMOTE_ROOT) or ''
names = re.findall(r'assets/(index-[A-Za-z0-9_-]+\.(?:js|css))', html)
print('线上 index.html 引用:', names or '(未找到)')
for n in names:
    code = (run(c, "curl -s -o /dev/null -w '%%{http_code}' --max-time 8"
                   " http://127.0.0.1:3602/admin/assets/%s" % n) or '').strip()
    sz = (run(c, "curl -s --max-time 8 http://127.0.0.1:3602/admin/assets/%s"
                  " | wc -c" % n) or '').strip()
    print('  %s -> HTTP %s, %s 字节' % (n, code, sz))
print('线上 assets 目录:', run(c, 'ls -1 %s/public/assets/' % REMOTE_ROOT))
