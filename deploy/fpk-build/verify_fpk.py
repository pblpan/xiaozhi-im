# -*- coding: utf-8 -*-
"""校验 deploy/fpk-build/xiaozhi-im.fpk —— 出包后必须跑一遍。

为什么需要它（而不是"fnpack 说 Packing successfully 就行"）：
  fnpack 只保证"能装"，不保证"装的是对的东西"。踩过的坑：
    · app/src 忘了跟着 server/ 更新 → 包能装、能跑，但跑的是上一版代码
      （现场表现是"新功能没有"，而不是报错，最难分辨）
    · manifest 的 version 与 app 里的 package.json 不一致 → 应用中心显示
      0.17.0、服务端自己报 0.16.0，客户截图来问"到底装没装上"
    · compose 漏了 UDP 3616 映射 → 客户端扫不到服务器（0.14.0 起客户端
      不再内置地址，这一条直接决定新装能不能用）

用法：
  python verify_fpk.py [fpk路径] [--expect-version X.Y.Z]

  不传 --expect-version 时，期望版本 = server/package.json 的 version
  （即"包里的东西必须跟仓库当前源码同版本"）。
  传一个**旧版本号**可以反向验证本脚本的判据真的会失败，例如：
      python verify_fpk.py --expect-version 0.0.1     # 应当全红 + 退出码 1

退出码：0 = 全部通过；1 = 有任一项不通过。
"""
import argparse
import io
import json
import os
import re
import sys
import tarfile

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.normpath(os.path.join(HERE, '..', '..', 'server'))
DEFAULT_FPK = os.path.join(HERE, 'xiaozhi-im.fpk')

# 包内不该出现的东西 —— 分发包不该带开发者的真实内网地址与域名
BANNED_IN_PKG = [
    (b'192.168.31.44', '开发者真实内网地址'),
    (b'takin.cc', '开发者真实域名'),
]

FAILS = []
OKS = []


def ok(name, extra=''):
    OKS.append(name)
    print('  \u2713 %s%s' % (name, ('  [' + extra + ']') if extra else ''))


def bad(name, extra=''):
    FAILS.append(name)
    print('  \u2717 %s%s' % (name, ('  [' + extra + ']') if extra else ''))


def check(cond, name, extra=''):
    (ok if cond else bad)(name, extra)
    return cond


def load_manifest(tar):
    """manifest 是 fpk 里的一个成员，无后缀。按文本读回 key=value。

    ⚠️ **不能直接拿仓库里那份 manifest 比对**：fnpack 打包时会重排它 ——
       键名后补空格对齐、行尾统一成 CRLF、并追加一行 `checksum=<md5>`。
       所以取值时必须 strip（否则 `' 0.17.0' != '0.17.0'`，看上去像版本没打对）。
    """
    m = [x for x in tar.getmembers() if x.name == 'manifest']
    if not m:
        return None, None
    raw = tar.extractfile(m[0]).read()
    text = raw.decode('utf-8')
    kv = {}
    for n, line in enumerate(text.split('\n')):
        if not line.strip():
            continue
        if '=' not in line:
            kv['__bogus_line_%d' % n] = line
            continue
        k, v = line.split('=', 1)
        kv[k.strip()] = v.strip()
    return kv, text


def inner_app(tar):
    """取出 app.tgz 并解成 {相对路径: bytes}（只读文本文件，二进制记大小）。"""
    m = [x for x in tar.getmembers() if x.name == 'app.tgz']
    if not m:
        return None
    data = tar.extractfile(m[0]).read()
    it = tarfile.open(fileobj=io.BytesIO(data), mode='r:gz')
    out = {}
    for mem in it.getmembers():
        if mem.isdir():
            out[mem.name.rstrip('/') + '/'] = b''
            continue
        f = it.extractfile(mem)
        out[mem.name] = f.read() if f else b''
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('fpk', nargs='?', default=DEFAULT_FPK)
    ap.add_argument('--expect-version', default=None,
                    help='期望版本；默认取 server/package.json 的 version')
    args = ap.parse_args()

    if not os.path.isfile(args.fpk):
        print('找不到 fpk：%s' % args.fpk)
        return 1

    with open(os.path.join(SERVER, 'package.json'), encoding='utf-8') as f:
        srv_ver = json.load(f)['version']
    want = args.expect_version or srv_ver

    print('=' * 68)
    print('核验 fpk：%s' % args.fpk)
    print('文件大小：%.2f MB' % (os.path.getsize(args.fpk) / 1024 / 1024))
    print('期望版本：%s%s' % (want, '' if args.expect_version else '（取自 server/package.json）'))
    print('=' * 68)

    tar = tarfile.open(args.fpk)
    names = [m.name for m in tar.getmembers()]

    # ---- 1. 容器结构 ----
    print('[1] 容器结构')
    for need in ('manifest', 'app.tgz', 'cmd/main', 'cmd/install_callback',
                 'cmd/uninstall_callback', 'cmd/upgrade_callback',
                 'config/privilege', 'config/resource', 'wizard/install', 'ICON.PNG'):
        check(need in names, '含 %s' % need)

    kv, mtext = load_manifest(tar)
    if not kv:
        bad('manifest 可读')
        print('\n无法继续：manifest 读不出来')
        return 1

    # ---- 2. manifest ----
    print('\n[2] manifest')
    check(kv.get('version') == want, 'version == %s' % want, '实际 %s' % kv.get('version'))
    check('__bogus_line_0' not in kv and not [k for k in kv if k.startswith('__bogus_line_')],
          '每一行都是 key=value（fnpack 的 key-value delimiter 报错源头）')
    check('desc=desc=' not in mtext, 'desc 没有重复的前缀（曾出现 "desc=desc=【产品介绍】"）')
    check('【v%s 更新】' % want in mtext or 'v%s' % want in mtext,
          'desc 里有 v%s 的更新条目' % want, )
    check('飞牛' in (kv.get('display_name') or '') or '飞牛' in mtext, 'display_name/desc 标明飞牛版')
    check(kv.get('platform') == 'all', 'platform=all（ARM + x86 双架构，内存小的机器也能装）')
    check(kv.get('service_port') == '3602', 'service_port=3602')
    check(kv.get('checkport') == 'true', 'checkport=true（应用中心才会检测端口占用）')
    check(kv.get('appname') == 'xiaozhi-im', 'appname=xiaozhi-im')

    # ---- 3. app.tgz 内容 ----
    print('\n[3] app.tgz 内容')
    inner = inner_app(tar)
    if inner is None:
        bad('app.tgz 可解压')
        return 1
    ok('app.tgz 可解压（%d 个成员）' % len(inner))

    # 版本一致性：manifest 与 app 内 package.json 必须逐字相同
    pkg_key = [k for k in inner if k.endswith('src/package.json') and 'node_modules' not in k]
    if not pkg_key:
        bad('app 内有 src/package.json')
    else:
        pkg = json.loads(inner[pkg_key[0]].decode('utf-8'))
        check(pkg.get('version') == want,
              'app/src/package.json 的 version 与 manifest 一致', '实际 %s' % pkg.get('version'))

    for need in ('src/src/index.js', 'src/src/push.js', 'src/src/routes/push.js',
                 'src/src/hub.js', 'src/src/license.js',
                 'src/public/index.html', 'src/node_modules.tar.gz',
                 'src/package.json', 'src/package-lock.json',
                 'docker/docker-compose.yaml',
                 'docker/coturn/turnserver.conf', 'docker/coturn/entrypoint.sh'):
        hit = [k for k in inner if k.endswith(need)]
        if hit:
            ok('含 %s' % need, '%d 字节' % len(inner[hit[0]]))
        else:
            bad('含 %s' % need)
    # ui 目录（manifest 的 desktop_uidir=ui）
    check(any(k.startswith('ui/') for k in inner) or any(k.endswith('/ui/') for k in inner),
          '含 ui 目录（manifest 声明 desktop_uidir=ui）')

    # node_modules.tar.gz 不能是空壳
    nm = [k for k in inner if k.endswith('src/node_modules.tar.gz')]
    if nm:
        check(len(inner[nm[0]]) > 100_000,
              'node_modules.tar.gz 不是空壳', '%.2f MB' % (len(inner[nm[0]]) / 1024 / 1024))

    # ---- 4. compose：端口与弱默认值 ----
    print('\n[4] docker-compose.yaml')
    cmp_key = [k for k in inner if k.endswith('docker-compose.yaml')]
    if not cmp_key:
        bad('找得到 docker-compose.yaml')
    else:
        cmp_txt = inner[cmp_key[0]].decode('utf-8')
        check('"3602:3602"' in cmp_txt, '映射 3602:3602（客户端连服务端）')
        check('3616:3616/udp' in cmp_txt,
              '映射 3616:3616/udp（局域网自动发现；0.14.0 起客户端不带默认地址，缺了就只能手填）')
        check('image: node:22-slim' in cmp_txt or 'node:22' in cmp_txt,
              '基础镜像为 node:22（node:sqlite 需要 22.x）')
        check(re.search(r'ADMIN_PASSWORD=\$\{ADMIN_PASSWORD:-\}', cmp_txt) is not None,
              'ADMIN_PASSWORD 无兜底默认值（安装脚本生成随机口令）')
        check(re.search(r'ADMIN_PASSWORD:-admin', cmp_txt) is None,
              'compose 里没有 "-admin" 这类弱默认口令兜底')
        check('TURN_CREDENTIAL=${TURN_PASSWORD:-}' in cmp_txt,
              'TURN_CREDENTIAL 无兜底默认值')
        check('/etc/machine-id:/host/machine-id:ro' in cmp_txt,
              '挂载宿主机 machine-id（授权机器码的来源，删了授权会失效）')

    # ---- 5. 安装脚本 ----
    print('\n[5] 安装/升级脚本')
    common = inner.get('cmd/_xiaozhi_common.sh', b'').decode('utf-8', 'ignore')
    if not common:
        # 有的打包会把 cmd/ 放在 fpk 根（不在 app.tgz 里）
        c = [x for x in tar.getmembers() if x.name == 'cmd/_xiaozhi_common.sh']
        if c:
            common = tar.extractfile(c[0]).read().decode('utf-8', 'ignore')
    check('force-recreate' in common,
          '装机脚本用 --force-recreate（fnOS 会在 init 与 callback 之间自己跑一次 compose）')
    check('xiaozhi_gen_admin_pass' in common, '装机脚本会生成随机管理台口令')
    check('random' in common.lower() or 'gen_secret' in common, '装机脚本会生成随机密钥')

    # ---- 6. 分发包不该带的东西 ----
    print('\n[6] 不该出现在包里的东西')
    # 只扫文本类文件，且**按文件打印命中位置** —— 只说"包里有生产地址"没法修，
    # 得知道是哪个文件带进去的（上一次就是管理台 bundle 里的帮助文案）。
    scanned = 0
    for pat, why in BANNED_IN_PKG:
        hit_files = []
        for k, v in inner.items():
            if not k.endswith(('.js', '.json', '.yaml', '.yml', '.html', '.css', '.md', '.sh', '.conf')):
                continue
            if pat in v:
                hit_files.append(k)
        scanned = 1
        check(not hit_files, '不含 %s（%s）' % (pat.decode(), why),
              '命中：' + ', '.join(hit_files[:5]) if hit_files else '')
    check(scanned == 1, '（文本文件已扫描）')

    print('\n' + '=' * 68)
    print('通过 %d 项，失败 %d 项' % (len(OKS), len(FAILS)))
    if FAILS:
        print('失败清单：')
        for f in FAILS:
            print('  ✗ ' + f)
        print('=' * 68)
        return 1
    print('全部通过 —— 可以上传飞牛应用中心了')
    print('=' * 68)
    return 0


if __name__ == '__main__':
    sys.exit(main())
