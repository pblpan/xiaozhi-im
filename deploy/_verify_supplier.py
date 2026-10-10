#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""热更后验证 product_master.supplier 列已加、且能查到。"""
import os, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from fnos_ssh import connect, run, put_file

REPO = os.path.dirname(HERE)
SERVER_DIR = os.path.join(REPO, 'server')
REMOTE_ROOT = '/vol1/@appcenter/xiaozhi-im/src'
CONTAINER = 'xiaozhi-im'

def find_dbfile(c):
    hits = (run(c, "find /vol1/@appcenter/xiaozhi-im /vol1/@appshare/xiaozhi-im"
                   " -name 'xiaozhi-im.db' -not -path '*src_pre_deploy*'"
                   " 2>/dev/null") or '').split()
    if not hits:
        raise SystemExit('线上找不到 xiaozhi-im.db')
    return hits[-1]

def to_container_path(c, hostpath):
    binds = run(c, "docker inspect --format '{{json .HostConfig.Binds}}' %s" % CONTAINER) or ''
    for b in binds.replace('[', ' ').replace(']', ' ').replace('"', ' ').split():
        parts = b.split(':')
        if len(parts) < 2:
            continue
        src, dst = parts[0].rstrip('/'), parts[1].rstrip('/')
        if hostpath.startswith(src + '/'):
            return dst.rstrip('/') + hostpath[len(src):]
    raise SystemExit('容器里找不到挂载点')

c = connect()
dbfile = find_dbfile(c)
indb = to_container_path(c, dbfile)
print('线上库（容器内路径）: ' + indb)

# 列检查：复用 _cols_probe.js
probe = os.path.join(HERE, '_cols_probe.js')
put_file(c, probe, REMOTE_ROOT + '/_cols_probe.js')
out = run(c, 'docker exec %s node /app/_cols_probe.js %s product_master=supplier 2>/dev/null'
           % (CONTAINER, indb)) or '(无输出)'
print('列校验: ' + out.strip())

# 样本 + 非空计数：用 _supplier_probe.js
sprobe = os.path.join(HERE, '_supplier_probe.js')
put_file(c, sprobe, REMOTE_ROOT + '/_supplier_probe.js')
out2 = run(c, 'docker exec %s node /app/_supplier_probe.js %s 2>/dev/null'
            % (CONTAINER, indb)) or '(无输出)'
print('—— 明细 ——')
print(out2.strip())
