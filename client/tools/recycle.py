#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""把文件/目录**送进回收站**，而不是硬删。

为什么要有这个：清理用户机器上的东西时，`rm` / `del /F` 是不可逆的 ——
一旦删错（认错了目录、把交付物当残留删了），没有任何补救机会。
Windows 回收站是系统级的"后悔药"，所以清理个人目录/drive 上的东西一律走这里。

用法：
  python tools/recycle.py "D:\\Program Files (x86)\\小智 IM" "C:\\...\\x.lnk"
  python tools/recycle.py --dry-run <path> [...]     # 只看会删什么，不动手

退出码 0 = 全部成功送进回收站；非 0 = 有失败项（逐条打印）。
"""
import ctypes
import os
import sys
from ctypes import wintypes


class SHFILEOPSTRUCTW(ctypes.Structure):
    _fields_ = [
        ('hwnd', wintypes.HWND),
        ('wFunc', wintypes.UINT),
        ('pFrom', wintypes.LPCWSTR),
        ('pTo', wintypes.LPCWSTR),
        ('fFlags', ctypes.c_uint16),
        ('fAnyOperationsAborted', wintypes.BOOL),
        ('hNameMappings', ctypes.c_void_p),
        ('lpszProgressTitle', wintypes.LPCWSTR),
    ]


FO_DELETE = 3
FOF_ALLOWUNDO = 0x40         # 关键：送回收站
FOF_NOCONFIRMATION = 0x10
FOF_SILENT = 0x04
FOF_NOERRORUI = 0x400

SHFileOperationW = ctypes.windll.shell32.SHFileOperationW
SHFileOperationW.argtypes = [ctypes.POINTER(SHFILEOPSTRUCTW)]
SHFileOperationW.restype = ctypes.c_int


def recycle(path):
    """把单个路径送回收站。返回 (成功与否, 说明)。"""
    if not os.path.exists(path):
        return False, '不存在（跳过）'
    # SHFileOperation 要求 pFrom 是"以 \0 分隔、再用 \0 收尾"的列表
    src = os.path.abspath(path) + '\0\0'
    op = SHFILEOPSTRUCTW()
    op.wFunc = FO_DELETE
    op.pFrom = src
    op.fFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI
    ret = SHFileOperationW(ctypes.byref(op))
    if ret != 0:
        return False, 'SHFileOperation 返回 %d' % ret
    if op.fAnyOperationsAborted:
        return False, '操作被中止（可能没有权限）'
    return True, '已送回收站'


def main():
    args = [a for a in sys.argv[1:] if a != '--dry-run']
    dry = '--dry-run' in sys.argv
    if not args:
        print(__doc__)
        return 2
    bad = 0
    for p in args:
        if dry:
            print('[DRY] 会送回收站: %s (%s)' % (p, '目录' if os.path.isdir(p) else '文件'))
            continue
        ok, why = recycle(p)
        if not ok:
            bad += 1
        print('[%s] %s  <- %s' % ('OK ' if ok else 'BAD', p, why))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
