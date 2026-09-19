# -*- coding: utf-8 -*-
"""验证安装包的「系统版本闸门」判据是否正确。

【为什么要单独测这一段】
  它是"Win7 用户会被拦下"的唯一保证。写错了（比如把 "6.1" 打成 "6.10"）
  的后果是**静默失效** —— 安装包照常生成、照常安装，Win7 用户装完看到
  「无法定位程序输入点 GetHostNameW」这种天书。没有任何环节会报错。

  而安装脚本的逻辑没法直接单测（要跑安装器），所以 pack_win.py 把判据抽成了
  只依赖 $R0 的函数 `CheckWinOld`，本脚本**用同一份常量**编译出一个测试程序去跑
  —— 测的是生产逻辑本身，不是抄一份来测。

【反向断言（防恒真）】
  只测"Win7 被判为不支持"是不够的：一个恒返回 1 的函数也能通过。
  所以必须同时断言 **Win10/11 必须放行**，并额外断言输出里 0 和 1 都出现过。

退出码：0=通过　1=判据错误　2=环境缺失（没有 makensis，无法验证）
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
CLIENT = os.path.dirname(HERE)
sys.path.insert(0, CLIENT)

from pack_win import OS_CHECK_FN, find_makensis  # noqa: E402

# 用例：CurrentVersion 注册表值 → 期望"是否不支持"(1=拦, 0=放行)
# ⚠️ 期望值必须我手写死，不能让被测代码来生成（否则就是自己证明自己）
CASES = [
    ('5.1',  1, 'Windows XP'),
    ('6.0',  1, 'Windows Vista'),
    ('6.1',  1, 'Windows 7  ← 本次的核心用例'),
    ('6.2',  1, 'Windows 8'),
    ('6.3',  1, 'Windows 8.1'),
    ('10.0', 0, 'Windows 10 / 11 ← 反向断言：绝不能把支持的系统拦下来'),
    ('',     0, '注册表读不到 → 放宽放行（宁可漏拦，不可误拦）'),
]

NSI = r'''Unicode true
SilentInstall silent
RequestExecutionLevel user
Name "gate test"
OutFile "gate_test.exe"

__OS_CHECK_FN__

Section
  FileOpen $9 "$EXEDIR\gate_result.txt" w
__STEPS__  FileClose $9
  Quit
SectionEnd
'''


def build_steps():
    out = []
    for val, _exp, _desc in CASES:
        out.append('  StrCpy $R0 "%s"\n' % val)
        out.append('  Call CheckWinOld\n')
        out.append('  FileWrite $9 "%s=$OsIsOld$\\r$\\n"\n' % val)
    return ''.join(out)


def main():
    try:
        makensis = find_makensis()
    except SystemExit as ex:
        print('无法验证：%s' % ex)
        return 2

    tmp = tempfile.mkdtemp(prefix='gate_test_')
    try:
        nsi_path = os.path.join(tmp, 'gate_test.nsi')
        script = (NSI.replace('__OS_CHECK_FN__', OS_CHECK_FN)
                     .replace('__STEPS__', build_steps()))
        with open(nsi_path, 'w', encoding='utf-8-sig', newline='\r\n') as f:
            f.write(script.replace('\r\n', '\n'))

        r = subprocess.run([makensis, '/V2', nsi_path], cwd=tmp,
                           capture_output=True, text=True, encoding='utf-8',
                           errors='replace')
        exe = os.path.join(tmp, 'gate_test.exe')
        if r.returncode != 0 or not os.path.isfile(exe):
            print('NSIS 编译失败（判据里的语法有问题就是装不出来的）：')
            print((r.stdout or '')[-2000:])
            print((r.stderr or '')[-2000:])
            return 1

        run = subprocess.run([exe], cwd=tmp, capture_output=True, text=True,
                             timeout=60)
        res_path = os.path.join(tmp, 'gate_result.txt')
        if not os.path.isfile(res_path):
            print('测试程序没产出结果文件（退出码 %s）' % run.returncode)
            return 1

        got = {}
        with open(res_path, encoding='utf-8', errors='replace') as f:
            for line in f:
                line = line.strip()
                if '=' in line:
                    k, v = line.split('=', 1)
                    got[k] = v.strip()

        ok = True
        print('%-8s %-8s %-8s %s' % ('版本号', '期望', '实际', '说明'))
        print('-' * 72)
        for val, exp, desc in CASES:
            actual = got.get(val)
            good = (actual == str(exp))
            ok = ok and good
            print('%-8s %-8s %-8s %s %s' % (
                val or '(空)', exp, actual, 'OK ' if good else '✗  ', desc))

        # 反向断言：输出不能是恒定的（否则"全拦"或"全放"都会显得通过）
        vals = set(got.get(v, '?') for v, _e, _d in CASES)
        print()
        if vals != {'0', '1'}:
            print('✗ 反向断言失败：所有用例输出都是 %s —— 判据是恒定的，等于没写' % vals)
            ok = False
        else:
            print('OK 反向断言：既有判为不支持(1) 也有放行(0)，判据确实在区分')

        # 用例数必须够（防止有人把 CASES 删空导致"零个失败=通过"）
        if len(CASES) < 5 or not got:
            print('✗ 用例过少或结果为空，本次不算通过')
            ok = False

        print()
        print('结果：%s' % ('通过' if ok else '失败'))
        return 0 if ok else 1
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == '__main__':
    sys.exit(main())
