#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""热更上线之后的体检（不用重传、不用重快照）。

    python deploy/_hotverify.py

干什么：
    1) 接口复探（401 = 路由挂上了，404 = 没挂上）
    2) 关键表的列齐不齐
    3) 「减货参照数」接口实测 —— 要打出**真数字**，不能全是 null

为什么单独成一个脚本：主热更脚本 `_deploy_server_hot.py` 在上传+重启之后
    就跑到头了，--restart-only 更小的路径又不做体检。手工分段跑容易漏，
    而且排查时要用到它的函数，索性把"验"这一步也做成一键的。
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import _deploy_server_hot as d  # noqa: E402
import fnos_ssh  # noqa: E402


def curl_probes(c):
    """接口复探。**输出必须用 print**：`fnos_ssh.run` 只执行不回显。"""
    script = (
        "for p in /api/deduct/sheets /api/deduct/reference"
        " /api/training/courses /api/admin/apps/price_tag/data;"
        " do printf '%s -> ' \"$p\";"
        " curl -s -o /dev/null -w '%{http_code}\\n'"
        " --max-time 8 http://127.0.0.1:3602$p; done"
    )
    print('  ' + (fnos_ssh.run(c, script) or '(无输出)').strip())


def main():
    c = d.connect()
    print('=== 线上体检 ===')
    print('容器: ' + (fnos_ssh.run(c, "docker ps --filter name=%s"
                                      " --format '{{.Names}}|{{.Status}}'"
                                   % d.CONTAINER) or '').strip())

    print('\n=== 1) 接口复探（401 = 挂上了，404 = 没挂上）===')
    curl_probes(c)

    print('\n=== 1b) 管理台 bundle 真能取到才是没白屏（期望 200）===')
    # 换 j、index.html 引入新 bundle 之后，这里能看到新的那个是不是 200
    print('  ' + d.check_admin_assets(c))

    print('\n=== 2) 迁移验列 ===')
    print('  tr_lesson  : ' + d.check_columns(c, 'tr_lesson', ['link_url']))
    print('  tr_progress: ' + d.check_columns(c, 'tr_progress',
                                              ['watched_sec', 'position_sec']))
    print('  inv_sheets : ' + d.check_columns(c, 'inv_sheets', ['sheet_type']))
    # 🔴 线上库是空的（一次盘点没做过、product_master 一条记录都没有），
    #    所以「参照数接口打出一个真数字」这件事**线上没法验** —— 没有数据可打。
    #    那就退一步验到能验的地方：把接口 SQL 依赖的**列**挨个验齐。
    #    参照数接口第一次上线、线上从没跑过，列名写错（比如 account_qty 漏了）
    #    是它最容易出的错；列全在，接口的 SQL 才谈得上能在真库上跑。
    print('  inv_scans  : ' + d.check_columns(c, 'inv_scans',
                                              ['barcode', 'sheet_type', 'sheet_no',
                                               'qty', 'account_qty', 'scanned_at']))
    print('  product_master: ' + d.check_columns(c, 'product_master',
                                                 ['barcode', 'name', 'spec', 'unit']))

    print()
    d.probe_reference(c)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
