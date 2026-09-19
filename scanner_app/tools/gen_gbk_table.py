#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成 scanner_app/lib/core/gbk_table.dart —— 内置 GBK 解码码表。

── 为什么要有这张表 ──────────────────────────────────────────────
独立扫码枪的商档是**导入 CSV**。而国内 Win 上的 Excel / WPS / 融通 BMS /
泰格 POS 导出的 CSV **默认是 GBK**（不是 UTF-8）—— 员工按默认存出来，
拿到手机上就是一堆乱码。这件事不解决，"导入商档"这个功能第一次真用就废了。

pub.dev 上那几个 GBK 包（gbk_codec / fast_gbk）都停在 2021 年，
environment 写的是 `sdk: >=2.x <3.0.0`，**在 Dart 3 上根本装不上**。
所以在构建前用 Python 把 GBK 全码表落成一张 Dart 常量，零依赖、纯 Dart。

── 表怎么排 ──────────────────────────────────────────────────────
GBK 双字节区：lead 0x81~0xFE（126 个），trail 0x40~0xFE 去掉 0x7F
（0x40~0x7E 共 63 个 + 0x80~0xFE 共 127 个 = 190 个）。
index = (lead - 0x81) * 190 + trailIndex，共 126 * 190 = 23940 个槽位。
未分配的槽位写 U+0000（Dart 侧读到它就当作"这个码不存在"）。

用法：
    python tools/gen_gbk_table.py
"""
import io
import os
import sys

TRAIL_N = 190  # 每个 lead 下的 trail 槽位数


def trail_index(t: int) -> int:
    return t - 0x40 if t <= 0x7E else t - 0x80 + 63


def trail_of(idx: int) -> int:
    return idx + 0x40 if idx < 63 else idx - 63 + 0x80


def js_escape(ch: str) -> str:
    """Dart 单引号字符串字面量里怎么写一个字符。

    除了这几个必须转义的，其余原样写（中文直接写进去，源文件用 UTF-8 存）。
    """
    o = ord(ch)
    if ch == '\\':
        return r'\\'
    if ch == "'":
        return r"\'"
    if ch == '$':
        return r'\$'
    if ch == '\n':
        return r'\n'
    if ch == '\r':
        return r'\r'
    if ch == '\t':
        return r'\t'
    if o < 0x20 or o == 0x7F:
        return '\\u%04X' % o
    if 0x80 <= o <= 0x9F:
        # C1 控制区：写进源码容易被编辑器/工具当成别的编码解释，转义掉最稳
        return '\\u%04X' % o
    return ch


def main() -> int:
    here = os.path.dirname(os.path.abspath(__file__))
    out = os.path.join(here, '..', 'lib', 'core', 'gbk_table.dart')
    out = os.path.normpath(out)

    slots = []
    assigned = 0
    for lead in range(0x81, 0xFF):
        row = []
        for ti in range(TRAIL_N):
            trail = trail_of(ti)
            try:
                ch = bytes([lead, trail]).decode('gbk')
                if len(ch) != 1:
                    ch = '\x00'
            except UnicodeDecodeError:
                ch = '\x00'
            if ch != '\x00':
                assigned += 1
            row.append(ch)
        slots.append(''.join(row))

    # 每行一个 lead（190 字符），用 Dart 的"相邻字符串字面量自动拼接"
    # 分成多行 —— 比一个 24000 字符的单行长串好读、也好 git diff。
    lines = []
    for i, row in enumerate(slots):
        lead = 0x81 + i
        body = ''.join(js_escape(c) for c in row)
        lines.append("    // lead 0x%02X\n    '%s'" % (lead, body))

    src = '''/// GBK → Unicode 解码码表（**自动生成，不要手改**）。
///
/// 由 `tools/gen_gbk_table.py` 生成：
///     python tools/gen_gbk_table.py
///
/// ── 为什么不是引一个 pub 包 ──────────────────────────────────────
/// pub 上那几个 GBK 包（gbk_codec / fast_gbk）都停在 2021 年，
/// environment 写的是 `sdk: >=2.x <3.0.0`，**在 Dart 3 上装不上**。
/// 而商档 CSV 在国内 Win 环境里**默认就是 GBK**（Excel / WPS / 融通 BMS /
/// 泰格 POS 导出的都是），不认 GBK 的话"导入商档"第一次真用就是一堆乱码。
///
/// ── 为什么不用 ffi 去调系统 API ──────────────────────────────────
/// Windows 有 MultiByteToWideChar、Android 没有。独立扫码枪要能在手机上
/// 自己解，只能自带表。代价约 50KB（23940 个 UTF-16 码元），换一个
/// "拿默认存出来的 CSV 直接能导"，值得。
///
/// ── 表的排布 ─────────────────────────────────────────────────────
/// 每个 lead 字节（0x81~0xFE）一行，行内 190 个槽位对应
/// trail 0x40~0x7E、0x80~0xFE（GBK 规范里 0x7F 不算有效 trail）。
/// 未分配的双字节码写 U+0000，解码时当作"这个码不存在"。
library;

/// 一维表：index = (lead - 0x81) * 190 + trailIndex。
const String kGbkTable = %s;

/// 每个 lead 下的槽位数（trail 0x40~0x7E 共 63 个 + 0x80~0xFE 共 127 个）。
const int kGbkTrailCount = %d;
''' % ('\n'.join(lines), TRAIL_N)

    with io.open(out, 'w', encoding='utf-8', newline='\n') as f:
        f.write(src)

    size = os.path.getsize(out)
    sys.stderr.write('written: %s\n' % out)
    sys.stderr.write('assigned code points: %d / %d\n' % (assigned, 126 * TRAIL_N))
    sys.stderr.write('file size: %.1f KB\n' % (size / 1024.0))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
