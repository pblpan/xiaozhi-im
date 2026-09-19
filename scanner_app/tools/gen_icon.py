#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成「小智扫码枪」的 Android 启动图标（五档 mipmap）。

── 为什么不用小智 IM 那张图 ────────────────────────────────────
两张图标一样的话，员工在桌面上一眼分不清哪个是聊天、哪个是扫码。
扫码枪自己一张：同色系（品牌绿 → 青），但主体换成**条码 + 扫描光带**，
远看也能和"聊天气泡"区分开。

── 为什么画在整数倍尺寸上 ─────────────────────────────────────
Android 的 mipmap 五档尺寸固定（48/72/96/144/192），直接按最终尺寸画、
不做缩放：缩放出来的条码竖线会糊成一团灰。每个尺寸都重新画一遍，
最细的那根线在最差的设备上也还在。

用法：
    python tools/gen_icon.py
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFilter

# 五档 mipmap：目录名 → 边长（px）
SIZES = [
    ('mipmap-mdpi', 48),
    ('mipmap-hdpi', 72),
    ('mipmap-xhdpi', 96),
    ('mipmap-xxhdpi', 144),
    ('mipmap-xxxhdpi', 192),
]

BRAND_TOP = (16, 185, 129)     # AppColors.brand  #10B981
BRAND_BOT = (6, 182, 212)      # AppColors.brand2 #06B6D4
DARK = (10, 26, 30)


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def rounded_mask(size, radius):
    m = Image.new('L', (size, size), 0)
    d = ImageDraw.Draw(m)
    d.rounded_rectangle([0, 0, size - 1, size - 1], radius=radius, fill=255)
    return m


def draw_icon(px):
    S = px * 4  # 4 倍超采样：条码竖线的边缘才不会毛
    img = Image.new('RGB', (S, S), BRAND_BOT)
    d = ImageDraw.Draw(img)

    # 背景：上绿下青的对角渐变
    for y in range(S):
        c = lerp(BRAND_TOP, BRAND_BOT, y / max(1, S - 1))
        d.line([(0, y), (S, y)], fill=c)

    # 白色圆角"卡片"（条码印在上面），占画面 62%
    pad = int(S * 0.19)
    card = [pad, int(S * 0.28), S - pad, int(S * 0.72)]
    d.rounded_rectangle(card, radius=int(S * 0.075), fill=(255, 255, 255))

    # 条码竖线：宽度交替（宽-细-宽-细…），间距按卡片宽度均匀分
    x0, y0, x1, y1 = card
    inner_pad = int((x1 - x0) * 0.11)
    bx0, bx1 = x0 + inner_pad, x1 - inner_pad
    by0, by1 = y0 + int((y1 - y0) * 0.20), y1 - int((y1 - y0) * 0.20)

    # 一维模式：1=细(1u) 2=中(2u) 3=宽(3u)，0=空(1u)
    pattern = [3, 1, 0, 2, 1, 0, 1, 3, 0, 1, 2, 0, 3, 1, 0, 1, 2, 0, 2, 1, 0, 1, 3, 0, 1, 1, 0, 2]
    unit = (bx1 - bx0) / (sum(p if p else 1 for p in pattern))
    x = bx0
    for p in pattern:
        w = unit * (p if p else 1)
        if p:
            d.rectangle([x, by0, x + w - max(1, unit * 0.12), by1], fill=DARK)
        x += w

    # 扫描光带：横穿条码的亮绿一条（"正在扫"的意思）
    band_h = max(2, int(S * 0.030))
    band_y = int((by0 + by1) / 2) - band_h // 2
    band = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    bd = ImageDraw.Draw(band)
    bd.rectangle([bx0 - unit, band_y, bx1 + unit, band_y + band_h],
                 fill=(16, 185, 129, 235))
    band = band.filter(ImageFilter.GaussianBlur(max(0.6, S * 0.004)))
    img = Image.alpha_composite(img.convert('RGBA'), band).convert('RGB')

    # 外层圆角（Android 自适应图标之外的设备会直接显示这张方形图）
    out = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    out.paste(img, (0, 0), rounded_mask(S, int(S * 0.22)))

    return out.resize((px, px), Image.LANCZOS)


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    root = os.path.normpath(os.path.join(here, '..', 'android', 'app', 'src', 'main', 'res'))
    for folder, px in SIZES:
        dest_dir = os.path.join(root, folder)
        if not os.path.isdir(dest_dir):
            sys.stderr.write('skip (no dir): %s\n' % dest_dir)
            continue
        icon = draw_icon(px)
        dest = os.path.join(dest_dir, 'ic_launcher.png')
        icon.save(dest, 'PNG', optimize=True)
        sys.stderr.write('%s  %dx%d  %d bytes\n'
                         % (folder, px, px, os.path.getsize(dest)))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
