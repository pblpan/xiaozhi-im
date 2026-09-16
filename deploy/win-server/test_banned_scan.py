# -*- coding: utf-8 -*-
"""scan_banned 的回归测试（不起服务、不装包，秒级）。

为什么单独有这么一个测试：出厂地址扫描这种东西最容易变成"看着有、其实没验"——
扫了个空目录也全绿。所以这里把四种情况都钉住：
  ① 真实 staging 不许命中；② 塞一个含真实地址的文件必须命中；
  ③ 空目录必须报 scanned=0（调用方靠下限拦住）；④ node_modules 必须跳过（第三方示例 IP 别误报）。

跑法：python deploy/win-server/test_banned_scan.py
"""
import importlib.util
import os
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))


def load_packer():
    p = os.path.join(HERE, 'pack_server_win.py')
    spec = importlib.util.spec_from_file_location('psw', p)
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


REAL_IP = bytes.fromhex('3139322e3136382e33312e3434')   # 192.168.31.44
REAL_DOMAIN = bytes.fromhex('74616b696e2e6363')          # takin.cc

FAILS = []


def check(cond, name, extra=''):
    print('  %s %s%s' % ('\u2713' if cond else '\u2717', name,
                         ('  [' + extra + ']') if extra else ''))
    if not cond:
        FAILS.append(name)


def main():
    m = load_packer()
    print('=' * 68)
    print('scan_banned 回归测试')
    print('=' * 68)

    print('\n[1] 真实 staging 不该命中')
    stage = os.path.join(m.BUILD, 'stage')
    if os.path.isdir(stage):
        hits, n = m.scan_banned(stage)
        check(len(hits) == 0, 'staging 里没有真实地址/域名',
              '%d 处命中 / 扫了 %d 个文件' % (len(hits), n))
        for rel, why in hits[:10]:
            print('      - %s  <- %s' % (rel, why))
    else:
        print('  - staging 不在（先跑一次 pack_server_win.py），跳过')

    tmp = tempfile.mkdtemp(prefix='scan_test_')
    try:
        print('\n[2] 注入含真实域名的管理台 bundle 必须命中')
        os.makedirs(os.path.join(tmp, 'public', 'assets'), exist_ok=True)
        with open(os.path.join(tmp, 'public', 'assets', 'index.js'), 'wb') as f:
            f.write(b'var help="https://' + REAL_DOMAIN + b'/admin";')
        with open(os.path.join(tmp, 'ok.txt'), 'wb') as f:
            f.write(b'no secrets here')
        hits, n = m.scan_banned(tmp)
        check(any('index.js' in h[0] for h in hits), '抓到了 index.js',
              ('命中：' + hits[0][1]) if hits else '')
        check(n == 2, '把两个文件都读了（不是只读一个就返回）', '%d 个' % n)

        print('\n[3] 空目录必须报 scanned=0（否则调用方的下限护栏就是摆设）')
        empty = tempfile.mkdtemp(prefix='scan_empty_')
        try:
            hits, n = m.scan_banned(empty)
            check(n == 0 and not hits, '空目录：scanned=0 且无命中', 'scanned=%d' % n)
        finally:
            shutil.rmtree(empty, ignore_errors=True)

        print('\n[4] node_modules 必须跳过（第三方代码里的示例 IP 不该误报）')
        nm = os.path.join(tmp, 'node_modules', 'foo')
        os.makedirs(nm, exist_ok=True)
        with open(os.path.join(nm, 'demo.js'), 'wb') as f:
            f.write(b'host="' + REAL_IP + b'"')
        hits, n = m.scan_banned(tmp)
        check(not any('node_modules' in h[0] for h in hits),
              'node_modules 里的命中被跳过', '%d 处命中' % len(hits))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    print('\n' + '=' * 68)
    if FAILS:
        print('失败 %d 项：' % len(FAILS))
        for f in FAILS:
            print('  \u2717 ' + f)
        return 1
    print('全部通过')
    print('=' * 68)
    return 0


if __name__ == '__main__':
    sys.exit(main())
