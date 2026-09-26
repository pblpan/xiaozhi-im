#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把本轮服务端改动推到飞牛上跑着的容器（rsync/版本库都没有，只能逐个文件传）。

背景（2026-09-26 实测）：
    线上容器的挂载是 `/vol1/@appcenter/xiaozhi-im/src -> /app`（rw），
    但那个目录**不是 git 仓库**（fpk 解包出来的，没有 .git），所以 `git pull` 无意义。
    而且它最后一次改动是 9-20 —— 也就是说**减货单上传那条接口一直没上线**
    （现场探测 `/api/deduct/sheets` 返回 404 not found，路由根本不存在）。
    所以「功能做好了」和「功能能用了」之间还差这一脚。

【顺序不能乱】
    1) 先给远端 src 拍整目录快照（回滚要用）
    2) 只传本轮改过的文件（不传 node_modules / data）
    3) 重启容器（新路由文件不会被运行中的 node 拾取）
    4) 复探：404 -> 401 才算路由真的挂上了

用法：
    python deploy/_deploy_server_hot.py --dry-run      # 只看要传哪些、服务端现在什么样
    python deploy/_deploy_server_hot.py                # 真干
    python deploy/_deploy_server_hot.py --restart-only  # 我只想重启（传完忘了重启时用）

回滚：`docker compose` 那一层没有快照，但 src 整目录快照在
    /vol1/@appcenter/xiaozhi-im/src_pre_deploy_<时间戳>/，拷回去再重启即可。
"""
import argparse
import os
import shlex
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from fnos_ssh import connect, put_file, run  # noqa: E402

REPO = os.path.dirname(HERE)
SERVER_DIR = os.path.join(REPO, 'server')
REMOTE_ROOT = '/vol1/@appcenter/xiaozhi-im/src'
CONTAINER = 'xiaozhi-im'

# 本轮自 0.21.3 = 9-25 那批文件**重传** + 本轮管理台。
# 🔴 2026-09-26 中午实测发现：上一轮 0.21.2 热更是**半截** —— 容器版本号
#    到了 0.21.2，但 routes/deduct.js、training.js 等根本不在（线上
#    /api/deduct 实测 404，不是当时记录的 401）。原因未查明（疑似 fpk
#    升级覆盖了 src），所以这里把 0.21.2 的全部文件重新列上，宁多勿漏。
# 🔴 用 git diff 算出来贴在这里，而不是"传整个 server 目录" ——
#    整目录上传会把别处可能的手改一起覆盖掉，而且没法预览。
FILES = [
    'package.json',
    # 🔴 2026-09-26 晚：修「飞牛上装好不弹密码向导」。
    #    setup.js 的 needSetup 判据加"环境没配 ADMIN_PASSWORD 就该弹"；
    #    config.js 加 custom.env 回读/回写（飞牛的 docker/.env 在宿主机、
    #    容器改不到，向导设的口令必须另找落脚点，否则重启后又变随机、反复弹）。
    'src/config.js',
    'src/setup.js',
    # 🔴 线上**一直缺**这两个（缺了容器直接起不来，报
    #    Cannot find module './routes/master'）：approval 是盘点单审批走的
    #    通用审批中心，master 是商档。index.js 里 require 了、文件却从没推上去过。
    'src/routes/master.js',
    'src/routes/approval.js',
    'src/appdata.js',
    'src/appguard.js',
    'src/appoverrides.js',
    'src/apps.js',
    'src/db.js',
    'src/index.js',
    'src/routes/deduct.js',
    'src/routes/inventory.js',
    'src/routes/training.js',
    'public/index.html',
    # 🔴 只传 index.html 实际引用的那两个 bundle。
    #    ⚠️ 这里必须**逐个列出 index.html 里引用的真实文件名**，不能"传整个
    #    public/assets"：vite 每次构建的产物名带哈希（index-XXXX.js），
    #    只换 index.html 不换 assets → 浏览器拿到新 html 却请求不存在的 js，
    #    白屏且控制台一片 404；只传 js 不改 index.html 同理。两者必须同批。
    #
    # 🔴 文件名是**按当轮构建**写的，改完管理台重出包后必须回来换。
    #    0.21.5 这轮是「培训中心课件外链 + 建课挂课件 + 课时改课件」，
    #    管理台这两项在「新建课程」弹窗和「课程结构」里，所以引用变了。
    'public/assets/index-Cu2GcK4-.js',
    'public/assets/index-CyRloi3S.css',
]


def describe_remote(c):
    """远端现在到底是个什么状态 —— 每次动手前先看一眼，别按想象做事。"""
    out = []
    # ⚠️ 注意 bind mount 的对应关系：宿主机 /vol1/@appcenter/xiaozhi-im/src
    #    整个挂进容器 /app，而容器里是 `node src/index.js`。
    #    所以宿主机上一律是 **REMOTE_ROOT/src/...**（多一层），下面的
    #    describe_remote 曾经漏了这层，报"deduct.js 没有"其实是假报警 ——
    #    文件好好的，别被它骗着去重复上传。
    out.append('容器状态: ' + run(c, "docker ps -a --filter 'name=xiaozhi'"
                                 " --format '{{.Names}}|{{.Status}}'"))
    out.append('远端有无 deduct.js: ' + run(c, 'test -f %s/src/routes/deduct.js'
                                            ' && echo 有 || echo 没有'))
    out.append('远端 src 最后改动: ' + run(c, "stat -c '%%y' %s" % REMOTE_ROOT))
    out.append('线上 index.html 引用的 bundle: ' + run(c,
               "grep -oE 'assets/index-[A-Za-z0-9_-]+\\.(js|css)'"
               " %s/public/index.html || echo '(无)'" % REMOTE_ROOT))
    out.append('线上 assets 实际内容: ' + run(c,
               'ls -1 %s/public/assets/ || echo "(空目录)"' % REMOTE_ROOT))
    return '\n'.join(out)


def check_columns(c, table, want):
    """线上那个 sqlite 里，指定表的列齐不齐。

    🔴 库文件叫 **`xiaozhi-im.db`**（在 DATA_DIR 下），不是通用的 db.sqlite。
        本地测试用错文件名会看到"列怎么都没加"的假象 —— 这个坑刚踩过。
    """
    # 排除 src_pre_deploy_* 快照目录，别把回滚副本当成线上库来读
    dbfile = (run(c, "find /vol1/@appcenter/xiaozhi-im -name 'xiaozhi-im.db'"
                     " -not -path '*src_pre_deploy*' 2>/dev/null") or '').split()[-1]
    if not dbfile:
        return '(线上找不到 xiaozhi-im.db — 读不到，别当通过)'
    got = run(c, "sqlite3 %s \"PRAGMA table_info(%s)\" 2>/dev/null"
                 "| awk -F'|' '{print $2}' | tr '\\n' ','" % (dbfile, table)) or ''
    miss = [w for w in want if w not in got]
    return ('%s   [%s]%s' % (got.rstrip(',') or '(空)',
                          os.path.basename(dbfile),
                          '' if not miss else '  → 缺: ' + ','.join(miss)))


def snapshot(c):
    stamp = time.strftime('%Y%m%d-%H%M%S')
    dst = '/vol1/@appcenter/xiaozhi-im/src_pre_deploy_%s' % stamp
    print('  快照 ->', dst)
    run(c, 'cp -a %s %s' % (REMOTE_ROOT, dst))
    # 留个最新指针，回滚脚本好找
    run(c, 'rm -f /vol1/@appcenter/xiaozhi-im/src_pre_deploy_latest;'
           ' ln -s %s /vol1/@appcenter/xiaozhi-im/src_pre_deploy_latest' % dst)
    print('  快照已就位')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dry-run', action='store_true', help='只看不传')
    ap.add_argument('--restart-only', action='store_true', help='跳过上传，只重启')
    args = ap.parse_args()

    c = connect()
    print('=== 动手前，远端现状 ===')
    print(describe_remote(c))

    if args.restart_only:
        print('\n=== 只重启 ===')
        run(c, 'docker restart %s' % CONTAINER)
        time.sleep(6)
        print('重启后: ' + run(c, "docker ps --filter name=%s --format '{{.Status}}'"
                               % CONTAINER))
        return 0

    missing = [f for f in FILES if not os.path.isfile(os.path.join(SERVER_DIR, f))]
    if missing:
        print('本地缺文件，不传：', missing)
        return 2

    print('\n=== 将上传 %d 个文件 ===' % len(FILES))
    for f in FILES:
        p = os.path.join(SERVER_DIR, f)
        print('  %-40s %d 字节' % (f, os.path.getsize(p)))

    if args.dry_run:
        print('\n（dry-run，到此为止）')
        return 0

    print('\n=== 1) 拍快照 ===')
    snapshot(c)

    print('\n=== 2) 上传 ===')
    for f in FILES:
        local = os.path.join(SERVER_DIR, f)
        remote = REMOTE_ROOT + '/' + f
        ok, detail = put_file(c, local, remote, backup=True, stamp='pre_hotfix')
        # 🔴 别假设 detail 一定是字节数 —— `run()` 在 stderr 非空时会把
        #    "[stderr] xxx" 拼到返回值后面，于是 detail 变成非数字，
        #    用 `'%d' % detail` 直接 TypeError。这里一律按字符串显示。
        print('  %-40s %s' % (f, ('OK ' + str(detail) + ' 字节') if ok else ('失败 ' + str(detail))))

    print('\n=== 3) 重启容器 ===')
    run(c, 'docker restart %s' % CONTAINER)
    time.sleep(6)
    print('  重启后: ' + run(c, "docker ps --filter name=%s --format '{{.Status}}'"
                             % CONTAINER))

    print('\n=== 4) 复探（等容器起来再看） ===')
    time.sleep(5)
    run(c, "for p in /api/deduct/sheets /api/admin/apps/price_tag/data;"
           " do printf '%%s -> ' \"$p\"; curl -s -o /dev/null -w '%%{http_code}\\n'"
           " --max-time 8 http://127.0.0.1:3602$p; done")

    print('\n=== 5) 验证数据库迁移真的跑了 ===')
    # 🔴 这一步是 2026-09-26 深夜补的。那次改了 db.js 给 tr_lesson 加列，
    #    但热更脚本**只验接口不验库** —— 而我自己在本地验证时也踩了坑：
    #    一直 `SELECT * FROM db.sqlite`，而项目真正用的是 **`xiaozhi-im.db`**，
    #    白折腾半天。所以这里务必核对**真实路径**。
    #    加了列但接口报 "no such column" 的话，管理台会整个白屏。
    print('  tr_lesson 列: ' + check_columns(c, 'tr_lesson',
                                            ['link_url']))
    print('  tr_progress 列: ' + check_columns(c, 'tr_progress',
                                              ['watched_sec', 'position_sec']))
    print('\n完成。401 = 路由已挂上（只是要鉴权）；404 = 还是没挂上。')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
