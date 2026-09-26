#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""线上 xiaozhi-im 容器状态体检（2026-09-26 晚发现 Restarting 循环 + src 被回退）。

背景：_deploy_server_hot.py 的 dry-run 报「容器 Restarting (1) 55 seconds ago」
    和「远端 src/routes/deduct.js: 没有」。前者可能是 filter 匹配到了多个容器
    （xiaozhi-im / xiaozhi-im-db ...），也可能真的在重启循环；后者说明线上 src
    被回退到 fpk 包内版本。这两个都得先查清，再决定热更清单。

这个函数只**读**，不做任何写操作。
"""
import sys
import os

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from fnos_ssh import connect, run  # noqa: E402

REMOTE_ROOT = '/vol1/@appcenter/xiaozhi-im/src'
CONTAINER = 'xiaozhi-im'

CMDS = [
    ('所有 xiaozhi* 容器（含已退出的）',
     "docker ps -a --filter 'name=xiaozhi' --format '{{.Names}}|{{.Status}}|{{.Image}}'"),
    ('容器日志尾部 40 行',
     "docker logs --tail 40 %s 2>&1" % CONTAINER),
    ('compose 里Declared的服务',
     "docker inspect %s --format '{{range .Config.Env}}{{println .}}{{end}}' "
     "2>&1 | grep -i -E 'port|admin' | head -20" % CONTAINER),
    ('宿主机端口监听',
     "ss -tlnp 2>/dev/null | grep -E '3602|3478|5349' || netstat -tlnp | grep -E "
     "'3602|3478'"),
    ('src 关键文件存在性',
     "cd %s/src && for f in routes/deduct.js routes/master.js routes/approval.js "
     "routes/inventory.js routes/training.js config.js setup.js index.js; do "
     "printf '%%-28s ' \"$f\"; test -f \"$f\" && echo 有 || echo '**没有**'; done" % REMOTE_ROOT),
    ('src 时钟', "stat -c '%%y  %%n' %s %s/src/index.js %s/package.json" % (REMOTE_ROOT, REMOTE_ROOT, REMOTE_ROOT)),
    ('src 里 app 版本号（package.json）',
     "grep -m1 '\"version\"' %s/package.json" % REMOTE_ROOT),
    ('快照目录（回滚点）',
     "ls -1dt /vol1/@appcenter/xiaozhi-im/src_pre_deploy_* 2>/dev/null | head -5 || echo '无快照'"),
    ('index.html 引用的 bundle',
     "grep -oE 'assets/index-[A-Za-z0-9_-]+\\.(js|css)' %s/public/index.html" % REMOTE_ROOT),
    ('assets 目录实际内容',
     "ls -1 %s/public/assets/ 2>/dev/null" % REMOTE_ROOT),
]


def main():
    c = connect()
    for title, cmd in CMDS:
        print('\n=== %s ===' % title)
        try:
            out = run(c, cmd)
            if isinstance(out, bytes):
                out = out.decode('utf-8', 'replace')
            print(out.strip() if out.strip() else '(空)')
        except Exception as e:  # 单个探测失败不该打断整轮体检
            print('探测失败: %r' % (e,))


if __name__ == '__main__':
    raise SystemExit(main())
