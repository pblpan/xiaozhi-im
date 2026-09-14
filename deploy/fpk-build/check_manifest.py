# -*- coding: utf-8 -*-
"""打包前校验 fpk 的 manifest，把 fnpack 的晦涩报错换成能看懂的白话。

【为什么需要它】2026-09-14 踩的坑：
  fnpack 的 manifest 解析器是**逐行 key=value**。只要有一行不含 '='，就直接抛
      parse manifest file ... key-value delimiter not found: <整行内容>
  然后把那一行的**全部文字**（1000 多字的产品说明）糊进错误信息里，
  既不说行号、也不说哪一行，光看日志完全定位不到问题。

  更阴的是：更新说明以前是**多行**写的（【v0.14.0 更新】独占一行），能打过包
  纯属巧合 —— 那几行正文里恰好含散文等号（"上午 4 小时 + 下午 4 小时 = 在岗 8 小时"）。
  新写的一段说明里一个等号都没有，于是直接把构建顶死了。
  顺带发现：那些多行说明**根本没被解析进 desc**（fnpack 只认每行第一个 '='），
  等于历次更新说明从未展示过。现已统一合并成一条 desc=。

【本脚本负责】在第 3 步 fnpack build 之前拦住这类问题，并给出可操作的信息。
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, '..', '..'))
MANIFEST = os.path.join(HERE, 'manifest')
SERVER_PKG = os.path.join(ROOT, 'server', 'package.json')

# fpk manifest 的合法键（按需扩充即可；不在表里的键会给个提醒，不算错）
KNOWN_KEYS = {
    'appname', 'version', 'display_name', 'desc', 'source', 'maintainer',
    'distributor', 'os_min_version', 'desktop_uidir', 'desktop_applaunchname',
    'service_port', 'checkport', 'micro_app', 'reloadui', 'platform', 'arch',
}


def main():
    errs, warns = [], []

    with open(MANIFEST, encoding='utf-8', newline='') as f:
        raw = f.read()
    lines = [l.rstrip('\r') for l in raw.split('\n')]

    # 1) 逐行必须有 '='（fnpack 的硬要求）
    for i, l in enumerate(lines, 1):
        if not l.strip():
            continue
        if '=' not in l:
            errs.append('第 %d 行没有 "="（fnpack 要求每行都是 key=value）\n'
                        '        该行开头: %s\n'
                        '        → 说明文字太长必须合并到同一条 desc= 里，用 <br> 分隔，'
                        '不要单独占行' % (i, l[:70]))

    # 2) 键值解析 + 重复键检查
    kv = {}
    for i, l in enumerate(lines, 1):
        if not l.strip() or '=' not in l:
            continue
        k, v = l.split('=', 1)
        k = k.strip()
        if k in kv:
            errs.append('键 %s 重复出现（第 %d 行与第 %d 行），fnpack 取哪个不确定'
                        % (k, kv[k][0], i))
        kv[k] = (i, v.strip())
        if k not in KNOWN_KEYS:
            warns.append('第 %d 行出现了没见过的键: %s' % (i, k))

    # 3) 版本号必须与 server/package.json 一致（版本号多处一致是铁律）
    if os.path.isfile(SERVER_PKG):
        with open(SERVER_PKG, encoding='utf-8') as f:
            srv = json.load(f).get('version', '')
        man = kv.get('version', (0, ''))[1]
        if man != srv:
            errs.append('manifest version=%s 与 server/package.json version=%s 不一致'
                        % (man or '(缺失)', srv))
    else:
        warns.append('读不到 server/package.json，跳过版本一致性检查')

    # 4) 本次版本的更新说明必须在 desc 里（最容易漏的一步）
    man_ver = kv.get('version', (0, ''))[1]
    desc = kv.get('desc', (0, ''))[1]
    if man_ver:
        tag = '【v%s 更新】' % man_ver
        if '【v%s 更新】' % man_ver not in desc:
            errs.append('desc 里没有找到本次版本的更新说明 %s\n'
                        '        → 发版前请把本版改动写进 desc（合并成同一行，用 <br> 分隔）'
                        % tag)

    # 5) desc 里不应该残留被误吞进来的其它键（如 arch="..."）
    for bad in re.findall(r'(?:^|<br>|>)([a-z_]{3,})="', desc):
        warns.append('desc 正文里疑似夹着一个被吞掉的键: %s="..."，可能无法展示或用意不明'
                     % bad)

    for w in warns:
        print('  [warn] %s' % w)
    if errs:
        print('\n  manifest 校验未通过（%d 项）：' % len(errs))
        for e in errs:
            print('   ✗ %s' % e)
        print('\n  文件: %s' % MANIFEST)
        return 1

    print('  manifest 校验通过：%d 行、%d 个键、version=%s、desc=%d 字'
          % (len([l for l in lines if l.strip()]), len(kv), man_ver, len(desc)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
