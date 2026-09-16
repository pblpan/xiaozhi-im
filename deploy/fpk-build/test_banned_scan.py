# -*- coding: utf-8 -*-
"""verify_fpk.py 地址扫描的回归测试：把真实地址塞进包的各个位置，必须都被抓住。

写的缘由：曾经把禁用串塞进 fpk 的 manifest，校验**照样全绿退出码 0**。三个原因：
  ① 只扫了 app.tgz 内部，fpk 顶层（manifest / cmd/* / config/* / ui/* / wizard/*）没扫；
  ② 后缀白名单跳过了 .cmd/.vbs/.txt，而装机脚本恰恰最容易写进真实地址；
  ③ `scanned = 1` 是写死的 → "（文本文件已扫描）"这条断言恒真，等于没验。
修完之后必须**实测它仍然会失败**，否则判据形同虚设。这个脚本就是那次实测。

跑法：python deploy/fpk-build/test_banned_scan.py [fpk路径]
"""
import copy
import io
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
PY = sys.executable
VERIFY = os.path.join(HERE, 'verify_fpk.py')
DEFAULT_FPK = os.path.join(HERE, 'xiaozhi-im.fpk')

LEAK = b'\nleak_host=https://' + bytes.fromhex('74616b696e2e6363') + b'\n'
# 校验输出里会把这串打出来，断言时得比对文本。同样不写明文（仓库是公开的）。
LEAK_TEXT = bytes.fromhex('74616b696e2e6363').decode()

# fpk 顶层的明文文件（无后缀，老逻辑全都跳过）+ app.tgz 内部的真实事故路径
TOP_CASES = ['manifest', 'cmd/install_callback', 'cmd/main', 'wizard/install']
INNER_CASES = ['docker/coturn/turnserver.conf', 'src/src/push.js', 'docker/docker-compose.yaml']

FAILS = []


def check(cond, name, extra=''):
    print('  %s %s%s' % ('\u2713' if cond else '\u2717', name,
                         ('  [' + extra + ']') if extra else ''))
    if not cond:
        FAILS.append(name)


def run_verify(fpk):
    r = subprocess.run([PY, VERIFY, fpk, '--expect-version', '0.17.0'],
                       capture_output=True, text=True, encoding='utf-8',
                       errors='replace', cwd=HERE)
    out = (r.stdout or '') + (r.stderr or '')
    return r.returncode, out


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_FPK
    if not os.path.isfile(src):
        print('找不到 fpk：%s' % src)
        return 1

    with tarfile.open(src, 'r') as t:
        outer = t.getmembers()
        outer_data = {m.name: (t.extractfile(m).read() if m.isfile() else None)
                      for m in outer}
    app_bytes = outer_data['app.tgz']
    with tarfile.open(fileobj=io.BytesIO(app_bytes), mode='r:gz') as a:
        amems = a.getmembers()
        adata = {m.name: (a.extractfile(m).read() if m.isfile() else None)
                 for m in amems}

    print('=' * 68)
    print('verify_fpk 地址扫描回归测试')
    print('包：%s' % src)
    print('=' * 68)

    print('\n[1] fpk 顶层明文注入（老逻辑全都漏）')
    for target in TOP_CASES:
        if target not in outer_data:
            print('  - %-28s 包内不存在，跳过' % target)
            continue
        tmp = tempfile.mkdtemp(prefix='neg_top_')
        bad = os.path.join(tmp, 'bad.fpk')
        with tarfile.open(bad, 'w') as t:
            for m in outer:
                if m.name == target:
                    pl = (outer_data[m.name] or b'') + LEAK
                    mi = copy.copy(m)          # 必须复制：改 m.size 会污染后续用例
                    mi.size = len(pl)
                    t.addfile(mi, io.BytesIO(pl))
                elif m.isfile():
                    t.addfile(m, io.BytesIO(outer_data[m.name]))
                else:
                    t.addfile(copy.copy(m))
        code, out = run_verify(bad)
        caught = code == 1 and '\u2717' in out and LEAK_TEXT in out
        check(caught, '%-28s 注入被抓' % target,
              '退出码 %d' % code if not caught else '退出码 1 + 命中注入串')
        shutil.rmtree(tmp, ignore_errors=True)

    print('\n[2] app.tgz 内部注入（当初真实事故就在 docker/coturn/turnserver.conf）')
    for target in INNER_CASES:
        if target not in adata:
            print('  - %-28s 包内不存在，跳过' % target)
            continue
        buf = io.BytesIO()
        with tarfile.open(fileobj=buf, mode='w:gz') as a:
            for m in amems:
                if m.name == target:
                    pl = (adata[m.name] or b'') + LEAK
                    mi = copy.copy(m)
                    mi.size = len(pl)
                    a.addfile(mi, io.BytesIO(pl))
                elif m.isfile():
                    a.addfile(m, io.BytesIO(adata[m.name]))
                else:
                    a.addfile(copy.copy(m))
        new_app = buf.getvalue()

        tmp = tempfile.mkdtemp(prefix='neg_inner_')
        bad = os.path.join(tmp, 'bad.fpk')
        with tarfile.open(bad, 'w') as t:
            for m in outer:
                if m.name == 'app.tgz':
                    mi = copy.copy(m)
                    mi.size = len(new_app)
                    t.addfile(mi, io.BytesIO(new_app))
                elif m.isfile():
                    t.addfile(m, io.BytesIO(outer_data[m.name]))
                else:
                    t.addfile(copy.copy(m))
        code, out = run_verify(bad)
        caught = code == 1 and '\u2717' in out
        # 报错只挑**带 ✗ 且带"命中："的失败行**：
        #   - 同一句里 ✓/✗ 都有，按字符串挑容易挑到那条 ✓（看着自相矛盾）；
        #   - 也别按具体地址挑 —— 注进去的是域名串，写死某个 IP 会挑空。
        hits = [l.strip() for l in out.splitlines()
                if '\u2717' in l and '\u547d\u4e2d\uff1a' in l]
        check(caught, '%-28s 注入被抓' % target,
              (hits[0][:66] if hits else '退出码 %d' % code))
        shutil.rmtree(tmp, ignore_errors=True)

    print('\n[3] 反"空扫"护栏本身要能失败（扫描列表下限 + 正控自检）')
    code, out = run_verify(src)
    check('扫描覆盖面够大' in out, '校验里有"扫描覆盖面够大"这条断言')
    check('扫描自检' in out, '校验里有正控自检（证明真读到了内容）')
    check(code == 0, '原始包仍然全绿', '退出码 %d' % code)

    print('\n' + '=' * 68)
    if FAILS:
        print('失败 %d 项：' % len(FAILS))
        for f in FAILS:
            print('  \u2717 ' + f)
        return 1
    print('全部通过 —— 地址判据立得住（注入必被抓）')
    print('=' * 68)
    return 0


if __name__ == '__main__':
    sys.exit(main())
