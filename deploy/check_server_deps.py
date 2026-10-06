#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""打包前检查：server/ 的依赖是不是**真的**都在 node_modules 里。

  python deploy/check_server_deps.py          # 检查
  python deploy/check_server_deps.py --list    # 只列不判

────────────────────────────────────────────────────────────────
为什么必须有这道闸（2026-10-05 真实踩中）
────────────────────────────────────────────────────────────────
部署向导的 SSH 执行层 `src/deploylib.js` **顶层**就 `require('ssh2')`，
而 `src/index.js:139` 是启动时同步 require 那条路由：

    app.use('/api/admin/deploy', require('./routes/deploy_wizard'));

所以只要 node_modules 里没有 ssh2，**服务端连启动都启动不了**。

当时的情形：ssh2 是手工装进**线上容器**的，本地 `server/node_modules`
和 `package.json` 都没同步 —— 而 package.json 里有 ssh2（所以 lock 检查、
`npm ci` 的报错都指向 package.json，看不出"本地 node_modules 缺东西"）。
结果：fpk 和 Win 安装包都打出来了、校验全绿、装到干净机器上服务端起不来。
（实测那版 fpk 里的 node_modules.tar.gz 只有 99 个包，ssh2/asn1/bcrypt-pbkdf
  /tweetnacl 全缺。）

判据故意不只看 package.json 的 dependencies：
  · 也扫 src 里所有 `require('非相对路径')` 的字面量 —— 这次能抓到的关键就是这个，
    因为 ssh2 在 package.json 里是**有的**，光比 package.json 会判成"齐"。
  · 内置模块（fs/path/...）用 node 自己的 module.builtinModules 名单排掉，
    不硬编码清单（硬编码迟早漏）。
"""
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SERVER = os.path.join(ROOT, 'server')
NM = os.path.join(SERVER, 'node_modules')
SRC = os.path.join(SERVER, 'src')

NODE_CANDIDATES = [
    r'C:\Users\pblpa\.workbuddy\binaries\node\versions\22.22.2-3\node.exe',
]


def find_node():
    for c in NODE_CANDIDATES:
        if os.path.isfile(c):
            return c
    for name in ('node', 'node.exe'):
        for p in os.environ.get('PATH', '').split(os.pathsep):
            c = os.path.join(p, name)
            if os.path.isfile(c):
                return c
    return None


def builtin_modules(node):
    """拿 node 自己认的内置模块名单。拿不到就退回一个保守的常见名单。"""
    fallback = {
        'assert', 'buffer', 'child_process', 'cluster', 'console', 'crypto', 'dgram',
        'dns', 'events', 'fs', 'http', 'http2', 'https', 'module', 'net', 'os', 'path',
        'perf_hooks', 'process', 'querystring', 'readline', 'stream', 'string_decoder',
        'timers', 'tls', 'tty', 'url', 'util', 'v8', 'vm', 'worker_threads', 'zlib',
    }
    if not node:
        return fallback
    try:
        out = subprocess.run(
            [node, '-e', 'console.log(JSON.stringify(require("module").builtinModules))'],
            capture_output=True, text=True, timeout=30)
        if out.returncode == 0:
            return set(json.loads(out.stdout.strip()))
    except Exception:  # noqa: BLE001
        pass
    return fallback


def pkg_name_of(spec):
    """从 require 的字符串里取出包名（处理 @scope/name 与子路径）。"""
    if spec.startswith('@'):
        parts = spec.split('/')
        return '/'.join(parts[:2])
    return spec.split('/')[0]


def scan_requires():
    """扫 src 下所有 .js 里的 require('字面量')，返回 {包名: [用到它的文件...]}"""
    pat = re.compile(r"""require\(\s*['"]([^'"]+)['"]\s*\)""")
    used = {}
    for dirpath, _dirs, files in os.walk(SRC):
        for fn in files:
            if not fn.endswith('.js'):
                continue
            full = os.path.join(dirpath, fn)
            try:
                text = open(full, encoding='utf-8').read()
            except Exception:  # noqa: BLE001
                continue
            for m in pat.finditer(text):
                spec = m.group(1)
                if spec.startswith('.') or spec.startswith('/'):
                    continue          # 相对/绝对路径
                if spec.startswith('node:'):
                    continue          # 显式内置
                used.setdefault(pkg_name_of(spec), []).append(
                    os.path.relpath(full, ROOT).replace('\\', '/'))
    return used


def installed(name):
    """node_modules 里有没有（含最简单的一层嵌套查找）"""
    p = os.path.join(NM, *name.split('/'))
    if os.path.isdir(p):
        return True
    # 兜底：被某个包的 node_modules 装着也算装上了
    for top in os.listdir(NM) if os.path.isdir(NM) else []:
        if top.startswith('.'):
            continue
        nested = os.path.join(NM, top, 'node_modules', *name.split('/'))
        if os.path.isdir(nested):
            return True
    return False


def main():
    only_list = '--list' in sys.argv

    if not os.path.isdir(NM):
        print('✗ server/node_modules 不存在 —— 先在 server/ 里跑：')
        print('    npm install --omit=dev')
        return 1

    node = find_node()
    builtins = builtin_modules(node)
    pkg = json.load(open(os.path.join(SERVER, 'package.json'), encoding='utf-8'))
    declared = dict(pkg.get('dependencies') or {})
    declared.update(pkg.get('devDependencies') or {})

    used = scan_requires()

    missing = []
    for name in sorted(declared):
        if not installed(name):
            missing.append((name, 'package.json 里声明了，但 node_modules 里没有'))

    # 关键：src 里 require 了但**没在 package.json 声明**的（这次就是这类最危险）
    undeclared = []
    for name in sorted(used):
        if name in builtins:
            continue
        if name in declared:
            continue
        if not installed(name):
            undeclared.append((name, '被 %s 用着，package.json 没声明、node_modules 也没有'
                               % (used[name][0])))

    if only_list:
        print('package.json 声明 %d 个；src 里 require 到 %d 个非内置包'
              % (len(declared), len([n for n in used if n not in builtins])))
        for name in sorted(used):
            if name in builtins:
                continue
            print('  %-18s %s' % (name, 'OK' if installed(name) else '**缺**'))
        return 0

    bad = missing + undeclared
    if not bad:
        print('✓ 服务端依赖齐备：%d 个声明包 + %d 个 src 实际 require 的包，全都在 node_modules 里'
              % (len(declared), len([n for n in used if n not in builtins])))
        return 0

    print('✗ 依赖不齐 —— 这样的包打出来，装到干净机器上**服务端起不来**：')
    for name, why in bad:
        print('    %-18s %s' % (name, why))
    print('')
    print('  修：cd server && npm install --omit=dev')
    print('  （注意：package.json 里有、lock 里也有，都**不代表** node_modules 里有。')
    print('    这次 ssh2 就是这么漏的 —— 它是手工装进线上容器的。）')
    return 1


if __name__ == '__main__':
    sys.exit(main())
