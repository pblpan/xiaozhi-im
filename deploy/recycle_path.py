#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""把文件/目录移入 Windows 回收站（而不是永久删除）。

为什么不用 rm / shutil.rmtree：
    永久删除是不可逆的。桌面上的目录里经常混着别的东西（装错位置的程序、
    别人给的材料），真删错了没法救。回收站可以右键还原，代价只是占点空间。

为什么不用 PowerShell 的 Add-Type + Microsoft.VisualBasic：
    本机安全策略会拦 Add-Type（"compiles and loads .NET code at runtime"）。
    这里直接调 shell32 的 SHFileOperationW，FOF_ALLOWUNDO 就是"可撤销"标志，
    不需要编译任何 .NET 代码。

用法：
    python recycle_path.py <路径> [更多路径...]
    python recycle_path.py --dry-run <路径>       # 只看会删什么，不动手

注意：
    FOF_ALLOWUNDO 只在**同一卷**内有效。跨卷移动会变成永久删除 —— 本脚本
    因此只支持本机存在的路径，不做跨盘搬运。
"""
import ctypes
import os
import sys
from ctypes import wintypes

FO_DELETE = 3
FOF_SILENT = 0x0004
FOF_NOCONFIRMATION = 0x0010
FOF_ALLOWUNDO = 0x0040          # ← 关键：进回收站，可还原
FOF_NOERRORUI = 0x0400
FOF_WANTNUKEWARNING = 0x4000    # 大到回收站放不下时至少提个醒（不静默变永久删）


class SHFILEOPSTRUCTW(ctypes.Structure):
    _fields_ = [
        ("hwnd", wintypes.HWND),
        ("wFunc", wintypes.UINT),
        ("pFrom", ctypes.c_void_p),   # double-null 结尾，手动构造缓冲
        ("pTo", ctypes.c_void_p),
        ("fFlags", wintypes.WORD),
        ("fAnyOperationsAborted", wintypes.BOOL),
        ("hNameMappings", ctypes.c_void_p),
        ("lpszProgressTitle", ctypes.c_wchar_p),
    ]


def recycle(paths):
    """把一批路径送进回收站。返回 (是否全部成功, Shell 返回码)。"""
    # pFrom 要求「;」不用，「\0」分隔且整体以 \0\0 收尾
    joined = "\0".join(os.path.abspath(p) for p in paths) + "\0"
    buf = ctypes.create_unicode_buffer(joined)
    op = SHFILEOPSTRUCTW()
    op.wFunc = FO_DELETE
    op.pFrom = ctypes.cast(buf, ctypes.c_void_p).value
    op.fFlags = FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI \
        | FOF_WANTNUKEWARNING
    rc = ctypes.windll.shell32.SHFileOperationW(ctypes.byref(op))
    return (rc == 0 and not op.fAnyOperationsAborted), rc


def describe(path):
    if os.path.isfile(path):
        return "文件 %.1f MB" % (os.path.getsize(path) / 1048576.0)
    n = 0
    total = 0
    for dirpath, _dirs, files in os.walk(path):
        for f in files:
            n += 1
            try:
                total += os.path.getsize(os.path.join(dirpath, f))
            except OSError:
                pass
    return "目录 %d 个文件 / %.1f MB" % (n, total / 1048576.0)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    dry = "--dry-run" in sys.argv
    if not args:
        print(__doc__)
        return 2
    missing = [p for p in args if not os.path.exists(p)]
    if missing:
        for p in missing:
            print("不存在: %s" % p)
        return 2
    for p in args:
        print("  %s   [%s]" % (p, describe(p)))
    if dry:
        print("\n(--dry-run：未执行)")
        return 0
    ok, rc = recycle(args)
    if ok:
        print("\n已移入回收站 ✓（可从回收站还原）")
        return 0
    print("\n失败，Shell 返回码 %s%s" % (rc, "（已被用户/系统取消）" if rc == 0 else ""))
    return 1


if __name__ == "__main__":
    sys.exit(main())
