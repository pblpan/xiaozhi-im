# -*- coding: utf-8 -*-
"""部署前探测：飞牛上现在跑的到底是什么版本、目录长什么样。

为什么要先探：记忆里"服务端线上代码在 /vol1/@appcenter/xiaozhi-im/src/src/"
（bind mount ...src → /app，启动命令 node src/index.js，所以**多一层 src**）。
这个双 src 结构反直觉，不先在真机上确认一遍就推，很容易推错层 ——
推错层的症状是"重启后功能没变"，会被误判成"部署没生效"。
"""
import os
import sys

import paramiko

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fnos_auth import HOST, PASS, USER  # noqa: E402

BASE = '/vol1/@appcenter/xiaozhi-im'


def run(c, cmd, timeout=120):
    _, so, se = c.exec_command("echo '%s' | sudo -S %s" % (PASS, cmd), timeout=timeout)
    out = so.read().decode('utf-8', 'replace').strip()
    err = se.read().decode('utf-8', 'replace').strip()
    if err and 'password for' not in err.lower():
        out += '\n[stderr] ' + err[:400]
    return out


def main():
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username=USER, password=PASS, timeout=20)
    try:
        print('=== 容器 ===')
        print(run(c, 'docker ps --format "{{.Names}}\\t{{.Status}}\\t{{.Image}}" | head -10'))
        print('\n=== 部署目录 ===')
        print(run(c, 'ls -la %s/' % BASE))
        print('\n=== src 这一层 ===')
        print(run(c, 'ls -la %s/src/ 2>/dev/null | head -15' % BASE))
        print('\n=== 线上 package.json 的 version ===')
        print(run(c, "grep -m1 '\\\"version\\\"' %s/src/src/package.json 2>/dev/null "
                     "|| echo '（src/src/package.json 不存在）'" % BASE))
        print('\n=== 线上有没有 inventory.js（M1 的接口）===')
        print(run(c, 'ls -la %s/src/src/routes/inventory.js 2>/dev/null '
                     '|| echo "（还没有 → 线上确实缺 M1）"' % BASE))
        print('\n=== 线上 src/src 的文件清单（前 30）===')
        print(run(c, 'ls %s/src/src/ 2>/dev/null | head -30' % BASE))
        print('\n=== compose 在哪个目录 ===')
        print(run(c, 'ls %s/docker/docker-compose.yaml %s/docker-compose.yaml 2>/dev/null' % (BASE, BASE)))
        print('\n=== 服务健康（本机 curl）===')
        print(run(c, 'curl -s -m 5 http://127.0.0.1:3602/api/health 2>/dev/null | head -5 '
                     '|| echo "（/api/health 无响应，试下面一条）"'))
        print(run(c, 'curl -s -m 5 -o /dev/null -w "HTTP %%{http_code}\\n" '
                     'http://127.0.0.1:3602/api/apps 2>/dev/null'))
    finally:
        c.close()


if __name__ == '__main__':
    main()
