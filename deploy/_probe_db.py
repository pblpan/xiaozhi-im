# -*- coding: utf-8 -*-
"""线上体检：容器 / 库文件列 / 接口状态 / coturn。

🔴 存在的意义（2026-09-26 深夜）：
    热更脚本只验接口不验库，而"加了列"这种事**接口验不出来** ——
    表结构不对时接口直接 500，管理台白屏，日志里还看不出是谁的错。

🔴 三个别再踩的坑（都踩过）：
    1. 库文件路径别猜。容器里 DATA_DIR=/data 是**容器内**的，宿主机上
       实测挂在 **/vol1/@appshare/xiaozhi-im/data**（不是 @appcenter！）。
       要用 `docker inspect --format '{{json .HostConfig.Binds}}'` 问出来。
    2. 🔴 飞牛这台机器**没有 sqlite3 命令**。用 `sqlite3 ... PRAGMA`
       查出来的"缺列"全是假报警。改用容器里的 node + node:sqlite。
    3. 读库要在**容器外**直接读那个文件：容器是 Up 的，别去 exec 里再读一遍
       （多次打开同一个库互不上锁，看到的东西可能不一样）。
"""
import sys, os, json
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from fnos_ssh import connect, run

CONTAINER = 'xiaozhi-im'
DB_NAME = 'xiaozhi-im.db'


def db_host_path(c):
    """从容器挂载关系反推宿主机上的库文件路径。"""
    raw = run(c, "docker inspect --format '{{json .HostConfig.Binds}}' " + CONTAINER) or ''
    try:
        binds = json.loads([l for l in raw.splitlines() if l.startswith('[')][-1])
    except Exception:
        return None
    for b in binds or []:
        src, dst, _ = (b.split(':') + [''])[:3]
        if dst == '/data' or dst.endswith('/data'):
            # ⚠️ 别用 os.path.join：这段路径是**飞牛 Linux 上**的，
            #    但本脚本跑在 Windows Python 里，os.path.join 会塞反斜杠过去，
            #    结果是 `/data\ ` 这种"看起来对、其实不存在"的路径。
            return src.rstrip('/') + '/' + DB_NAME
    return None


PROBE = os.path.join(HERE, '_cols_probe.js')
PROBE_REMOTE = '/vol1/@appcenter/xiaozhi-im/src/_cols_probe.js'


def cols(c, db_container_side, specs):
    """🔴 飞牛没装 sqlite3，用容器里的 node 读（见 _cols_probe.js 顶部说明）。

    ⚠️ 传进去的路径是**容器内**能看到的那个（/data/...），不是宿主机路径 ——
        容器内看不到 /vol1/...，用宿主机路径会报 "unable to open database file"。
    """
    from fnos_ssh import put_file
    put_file(c, PROBE, PROBE_REMOTE, backup=False, stamp=None)
    try:
        args = ' '.join('%s=%s' % (t, ','.join(w)) for t, w in specs)
        out = run(c, "docker exec %s node /app/_cols_probe.js %s %s 2>&1"
                     % (CONTAINER, db_container_side, args))
        print((out or '').strip())
    finally:
        run(c, 'rm -f %s' % PROBE_REMOTE)


def main():
    c = connect()
    print('=== 容器 ===')
    print(run(c, "docker ps -a --format '{{.Names}}|{{.Status}}'"))

    db = db_host_path(c)
    print('\n=== 库文件 ===')
    print('  宿主机路径: %s' % db)
    print('  容器内路径: /data/xiaozhi-im.db')
    if db:
        print('  ' + (run(c, "ls -la '%s' 2>&1 | head -2" % db) or '').strip().replace('\n', '\n  '))
        print('=== 关键表的列 ===')
        cols(c, '/data/xiaozhi-im.db', [
            ('tr_lesson', ['link_url']),
            ('tr_progress', ['watched_sec', 'position_sec']),
            ('inv_sheets', ['sheet_type', 'approval_status']),
        ])

    print('\n=== 线上接口复探 ===')
    print(run(c, "for p in /api/health /api/training/courses /api/deduct/sheets;"
                 " do printf '%s -> ' '$p';"
                 " curl -s -o /dev/null -w '%{http_code}\\n'"
                 " --max-time 8 http://127.0.0.1:3602$p; done"))

    print('\n=== 线上 index.html 引用的 bundle ===')
    print(run(c, "grep -oE 'assets/index-[A-Za-z0-9_-]+\\.(js|css)'"
                 " /vol1/@appcenter/xiaozhi-im/src/public/index.html"))

    print('\n=== coturn ===')
    print(run(c, "docker inspect --format '{{json .HostConfig.Binds}}' xiaozhi-im-turn"))
    print(run(c, "docker logs --tail 3 xiaozhi-im-turn 2>&1"))


if __name__ == '__main__':
    main()
