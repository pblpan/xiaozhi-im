#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""只热更管理台前端（public/index.html + 它引用的 assets），**不重启容器**。

为什么单独要这么个脚本：
    管理台是纯静态资源，服务端进程直接从 /app/public 读盘，**换文件即生效**，
    根本不需要 `docker restart`。而 `_deploy_server_hot.py` 会顺带把 50 多个
    src/*.js 一起推上去并重启容器 —— 只改了一个前端 bug 时，那是没必要的
    爆炸半径（重启 = 全站断连十几秒，而且会把 src 一起替换掉）。

    所以「只动管理台」就走这里：
        构建 → 现读本地 index.html 拿 assets 名 → 只推这几个文件 → HTTP 复验。

    ⚠️ 这条「换文件即生效」只对 public/ 下的静态资源成立。
       src/*.js 是 Node 进程启动时 require 进内存的，改了**必须重启**才生效。

🔴 必须守住的那条铁规矩：index.html 与它引用的 assets 名字**要同批上传**。
    两者若不同源，就是"新 index.html 引用一个没传上去的 js" → 管理台白屏。
    asset_files() 直接读本地 index.html 现取，天然同源，构建完不用回来改清单。

用法：
    cd admin && npm run build            # 1) 先在本地构建
    python deploy/_deploy_admin_bundle.py --dry-run   # 2) 只看要推哪几个
    python deploy/_deploy_admin_bundle.py             # 3) 真推 + HTTP 复验

回滚：put_file 会留 .bak.pre_admin 备份；把 index.html.bak.pre_admin 拷回去即可。
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from fnos_ssh import connect, put_file, run  # noqa: E402
from _deploy_server_hot import (  # noqa: E402
    SERVER_DIR, REMOTE_ROOT, CONTAINER, asset_files,
)


def served_bundle(c):
    """线上 /admin/ 现在引用的是哪个 bundle。"""
    return run(c, "grep -oE 'assets/index-[A-Za-z0-9_-]+\\.(js|css)'"
                   " %s/public/index.html || echo '(无)'" % REMOTE_ROOT)


def probe_asset(c, name):
    """用 HTTP 真取一次这个资源，回状态码 + 字节数。

    🔴 静态资源前缀是 **/admin/assets/**，不是 /assets/（写错会一直 404，
        白白怀疑"没生效"）。走容器内 127.0.0.1:3602 探，绕开外网。
    """
    out = run(c, "curl -s -o /dev/null -w '%%{http_code} %%{size_download}'"
                 " --max-time 10 http://127.0.0.1:3602/admin/%s" % name)
    return (out or '(无响应)').strip()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--dry-run', action='store_true', help='只看不传')
    args = ap.parse_args()

    files = ['public/index.html'] + asset_files()
    missing = [f for f in files
               if not os.path.isfile(os.path.join(SERVER_DIR, f))]
    if missing:
        print('本地缺文件，先构建：', missing)
        return 2

    c = connect()
    print('=== 动手前 ===')
    print('  线上 index.html 引用: ' + served_bundle(c).strip())
    print('\n=== 将上传 %d 个文件（不重启容器）===' % len(files))
    for f in files:
        print('  %-42s %d 字节' % (f, os.path.getsize(os.path.join(SERVER_DIR, f))))

    if args.dry_run:
        print('\n（dry-run，到此为止）')
        return 0

    print('\n=== 上传 ===')
    ok_all = True
    for f in files:
        ok, detail = put_file(c, os.path.join(SERVER_DIR, f),
                              REMOTE_ROOT + '/' + f,
                              backup=True, stamp='pre_admin')
        print('  %-42s %s' % (f, ('OK ' + str(detail) + ' 字节') if ok
                              else ('失败 ' + str(detail))))
        ok_all = ok_all and ok

    print('\n=== 复验（静态资源不需要重启，直接取）===')
    print('  线上 index.html 引用: ' + served_bundle(c).strip())
    for f in files:
        if f.startswith('public/assets/'):
            name = f[len('public/'):]
            print('  /admin/%s -> %s' % (name, probe_asset(c, name)))

    return 0 if ok_all else 1


if __name__ == '__main__':
    raise SystemExit(main())
