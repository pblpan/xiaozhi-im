#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""备份并（可选）清理与「小智 IM / 工厂管理系统V2」相关的卸载注册表项。

为什么要有这个脚本：
    NSIS / electron-builder 安装器都会把「上次装到哪」写进
    ...\\Uninstall\\<名字> 的 InstallLocation。之后无论你换到哪个目录装，
    安装器都会优先沿用那个旧路径 —— 于是出现「明明装成功，文件却在老地方」，
    而测试脚本只会报「安装目录未创建」，看不出真因。
    删测试目录前先把这些键 dump 出来，随时能照着恢复。

用法：
    python backup_uninstall_keys.py            # 只看 + 备份
    python backup_uninstall_keys.py --delete   # 备份后删除（键会残留指向已删目录）
"""
import os
import sys
import datetime
import winreg

# 32 位安装器写的项会落在 WOW6432Node 下 —— 只扫主路径会「看不见但确实生效」
UNINSTALL_BASES = [
    r"Software\Microsoft\Windows\CurrentVersion\Uninstall",
    r"Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall",
]
ROOTS = [(winreg.HKEY_CURRENT_USER, "HKCU"), (winreg.HKEY_LOCAL_MACHINE, "HKLM")]
KEYS = ("小智", "工厂")
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "backup", "uninstall_keys_backup.txt")


def related():
    """列出 DisplayName 含关键字的卸载项 -> [(root, root_name, base, subkey, display_name)]"""
    hits = []
    for root, root_name in ROOTS:
        for base in UNINSTALL_BASES:
            try:
                h = winreg.OpenKey(root, base, 0, winreg.KEY_READ)
            except FileNotFoundError:
                continue
            i = 0
            while True:
                try:
                    sub = winreg.EnumKey(h, i)
                    i += 1
                except OSError:
                    break
                try:
                    sh = winreg.OpenKey(h, sub, 0, winreg.KEY_READ)
                    try:
                        dn = str(winreg.QueryValueEx(sh, "DisplayName")[0])
                    except OSError:
                        dn = ""
                    winreg.CloseKey(sh)
                except OSError:
                    continue
                if any(k in dn for k in KEYS):
                    hits.append((root, root_name, base, sub, dn))
            winreg.CloseKey(h)
    return hits


def dump(root, base, sub):
    path = base + "\\" + sub
    h = winreg.OpenKey(root, path, 0, winreg.KEY_READ)
    rows = []
    i = 0
    while True:
        try:
            n, v, t = winreg.EnumValue(h, i)
            i += 1
            rows.append((n, v, t))
        except OSError:
            break
    winreg.CloseKey(h)
    return rows


def main():
    do_delete = "--delete" in sys.argv
    hits = related()
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    out = ["# 卸载注册表备份（删 小智IM-Windows 测试目录前留底）\n",
           "# 生成时间 %s\n" % datetime.datetime.now()]
    print("找到 %d 个相关卸载项：" % len(hits))
    for root, root_name, base, sub, dn in hits:
        rows = dump(root, base, sub)
        print("  [%s] subkey=%r  DisplayName=%r" % (root_name, sub, dn))
        out.append("\n[%s\\\\%s\\\\%s]\n" % (root_name, base, sub))
        for n, v, t in rows:
            out.append("%-26s = %r  (type=%d)\n" % (n, v, t))
            print("        %-22s = %r" % (n, v))
    with open(OUT, "w", encoding="utf-8") as f:
        f.write("".join(out))
    print("\n备份 -> %s" % OUT)

    if not do_delete:
        print("（仅备份。要删除残留键请加 --delete）")
        return
    print("\n删除残留卸载项：")
    for root, root_name, base, sub, dn in hits:
        try:
            winreg.DeleteKey(root, base + "\\" + sub)
            print("  [%s] %r 已删（安装目录本身未动）" % (root_name, dn))
        except OSError as e:
            print("  [%s] %r 删除失败：%s（多半权限不够，需管理员）" % (root_name, dn, e))


if __name__ == "__main__":
    main()
