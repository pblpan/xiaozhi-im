#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""在「产物」里核实 Dart 常量串是否真的进去了。

为什么需要它：Flutter 的 Dart 字符串在 AOT 产物里是 **UTF-16LE**
（iOS/Mac 除外，那也要按 utf-16-le 看），不是 UTF-8；而 Kotlin/Java 原生串
在 classes.dex 里才是 UTF-8。只搜一处/只搜一种编码 ⇒ 会把「代码没进包」
误判成「已经进了」，或者反过来把好好的包误判成漏代码。

铁律：**先拿一个"已知存在"的串校准探针**（--calibrate，默认 '同步商品档案'），
校准不过就直接判 INVALID，不许拿后面的 0 命中当结论。

用法：
  python tools/probe_aot_strings.py --apk build/app/outputs/flutter-apk/app-release.apk \
      --win build/windows/x64/runner/Release/xiaozhi_im_client.exe \
      --expect "三遍实盘互比" --expect "不靠账面数" \
      --absent "直接去抽盘" --absent "上一轮没有差异"
"""
import argparse
import io
import os
import sys
import zipfile

# 每条候选在产物里可能出现的编码。注意顺序：UTF-16LE 命中优先级最高。
ENCODINGS = ("utf-16-le", "utf-8")


def enc_variants(s: str):
    out = []
    for enc in ENCODINGS:
        try:
            out.append((enc, s.encode(enc)))
        except UnicodeEncodeError:
            pass
    return out


def count_all(hay: bytes, needle: bytes) -> int:
    """非重叠计数；needle 为空时返回 0（避免死循环）。"""
    if not needle:
        return 0
    n, start = 0, 0
    while True:
        i = hay.find(needle, start)
        if i < 0:
            return n
        n += 1
        start = i + len(needle)


def probe_blob(hay: bytes, s: str) -> int:
    """返回该串在 blob 里的最大命中数（跨编码取 max）。

    取 max 而不是 sum：同一段字面量一般只会以一种编码落地，
    相加会把「恰好两种编码都撞上」的噪音算成 2。
    """
    return max((count_all(hay, n) for _, n in enc_variants(s)), default=0)


def load_apk_payloads(apk_path: str):
    """APK 里可能承载 Dart 串的是各 ABI 的 libapp.so。"""
    payloads = {}
    with zipfile.ZipFile(apk_path) as z:
        for name in z.namelist():
            if name.endswith("libapp.so"):
                payloads[name] = z.read(name)
    return payloads


def load_win_payloads(exe_path: str):
    """Windows 桌面端：Dart 串在 exe 旁边的 data/app.so（不在 exe 里）。"""
    payloads = {}
    root = os.path.dirname(os.path.abspath(exe_path))
    for rel in ("data/app.so", "data/flutter_assets/kernel_blob.bin"):
        p = os.path.join(root, *rel.split("/"))
        if os.path.isfile(p):
            with open(p, "rb") as f:
                payloads[rel] = f.read()
    if not payloads and os.path.isfile(exe_path):
        # 兜底：有的构建会把 dart 快照塞进 exe 本体
        with open(exe_path, "rb") as f:
            payloads["<exe>"] = f.read()
    return payloads


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--apk")
    ap.add_argument("--win")
    ap.add_argument("--expect", action="append", default=[],
                    help="必须命中的串（可重复）")
    ap.add_argument("--absent", action="append", default=[],
                    help="必须 0 命中的串（可重复，用于验证旧文案已下线）")
    ap.add_argument("--calibrate", default="同步商品档案",
                    help="已知一定存在的串，用来证明探针本身没坏")
    a = ap.parse_args()

    sets = {}
    if a.apk:
        if not os.path.isfile(a.apk):
            print("[FATAL] APK 不存在: %s" % a.apk)
            return 2
        sets["APK"] = load_apk_payloads(a.apk)
    if a.win:
        if not os.path.isfile(a.win):
            print("[FATAL] exe 不存在: %s" % a.win)
            return 2
        sets["WIN"] = load_win_payloads(a.win)
    if not sets:
        print("[FATAL] 至少给 --apk 或 --win 之一")
        return 2

    ok = True
    cal = a.calibrate
    print("=" * 68)
    print("校准串（必须 >0，否则探针本身有问题，后面结论一律不算）: %r" % cal)
    for tag, payloads in sets.items():
        if not payloads:
            print("  [FATAL] %s: 一个宿主文件都没找到（libapp.so / data/app.so）" % tag)
            ok = False
            continue
        for name, blob in sorted(payloads.items()):
            c = probe_blob(blob, cal)
            flag = "OK " if c > 0 else "BAD"
            if c <= 0:
                ok = False
            print("  [%s] %-42s %s 校准命中=%d (size=%.1fMB)"
                  % (flag, tag + "/" + name, "", c, len(blob) / 1048576.0))
    if not ok:
        print("\n[INVALID] 校准没过 ⇒ 本次探针结果不可采信。")
        return 3

    def scan(kind, items, want_hit):
        nonlocal ok
        if not items:
            return
        print("-" * 68)
        print("%s（%s）" % ("必须命中" if want_hit else "必须 0 命中", kind))
        for s in items:
            total = 0
            per = []
            for tag, payloads in sets.items():
                for name, blob in sorted(payloads.items()):
                    c = probe_blob(blob, s)
                    total += c
                    per.append("%s=%d" % (tag, c))
            good = (total > 0) if want_hit else (total == 0)
            if not good:
                ok = False
            print("  [%s] %-38r %s" % ("OK " if good else "BAD", s, " ".join(per)))

    scan("expect", a.expect, True)
    scan("absent", a.absent, False)

    print("=" * 68)
    print("结论: %s" % ("PASS —— 产物核验通过" if ok else "FAIL —— 有串对不上，见上面 BAD 行"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
