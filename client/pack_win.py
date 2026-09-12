# -*- coding: utf-8 -*-
"""把 Flutter Windows Release 产物整体打成 zip（客户端绿色版分发）。

Windows 产物必须整体分发：exe + 各插件 dll + data/ 目录，少一个都起不来。
所以这里遍历 Release 目录下**全部**文件，不带顶层目录（与历史包结构一致）。
"""
import os
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, 'build', 'windows', 'x64', 'runner', 'Release')
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    'D:', os.sep, 'Users', 'pblpa', 'Desktop', '小智 IM',
    '小智IM-Windows-v0.7.0.zip')


def main():
    if not os.path.isdir(SRC):
        print('找不到构建产物:', SRC)
        return 1
    n = 0
    with zipfile.ZipFile(OUT, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for root, dirs, files in os.walk(SRC):
            for f in files:
                p = os.path.join(root, f)
                arc = os.path.relpath(p, SRC).replace(os.sep, '/')
                z.write(p, arc)
                n += 1
    print('打包文件数:', n)
    print('输出:', OUT)
    print('大小: %.1f MB' % (os.path.getsize(OUT) / 1024 / 1024))
    return 0


if __name__ == '__main__':
    sys.exit(main())
