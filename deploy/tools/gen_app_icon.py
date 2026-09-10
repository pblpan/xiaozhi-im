#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成小智IM 的 App 启动图标 + Windows .ico
设计：圆角矩形 + 青绿渐变 + 白色「X」（小智拼音首字母）
输出：android 各 mipmap 尺寸 + windows/runner/resources/app_icon.ico
"""
import os, math
from PIL import Image, ImageDraw, ImageFont

# ---- 设计参数 ----
BRAND = (16, 185, 129)    # #10B981 青绿
BRAND2 = (6, 182, 212)    # #06B6D4 青蓝
WHITE = (255, 255, 255)

# 启动图标尺寸 (Android 各密度)
ANDROID_SIZES = {
    'mipmap-mdpi': 48,
    'mipmap-hdpi': 72,
    'mipmap-xhdpi': 96,
    'mipmap-xxhdpi': 144,
    'mipmap-xxxhdpi': 192,
}
WINDOWS_ICO = 256

OUTPUT_BASE = r'C:\Users\pblpa\WorkBuddy\2026-09-08-11-01-42\xiaozhi-im\client'
ANDROID_DIR = os.path.join(OUTPUT_BASE, 'android', 'app', 'src', 'main', 'res')
WINDOWS_ICON = os.path.join(OUTPUT_BASE, 'windows', 'runner', 'resources', 'app_icon.ico')


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def make_base(size: int) -> Image.Image:
    """画一张 size×size 的基础图标（圆角矩形 + 青绿渐变 + 白 X）"""
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    radius = int(size * 0.22)

    # 1) 渐变矩形：左下 #06B6D4 → 右上 #10B981 对角线
    grad = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    gd = ImageDraw.Draw(grad)
    for y in range(size):
        t = y / max(size - 1, 1)
        # 对角线：从右上 BRAND 到左下 BRAND2
        for x in range(size):
            tx = x / max(size - 1, 1)
            mix = (tx + t) / 2
            r, g, b = lerp(BRAND2, BRAND, mix)
            gd.point((x, y), fill=(r, g, b, 255))
    # 圆角蒙版
    mask = Image.new('L', (size, size), 0)
    md = ImageDraw.Draw(mask)
    md.rounded_rectangle((0, 0, size, size), radius=radius, fill=255)
    img.paste(grad, (0, 0), mask)

    # 2) 白色 X
    #   找字体
    font_paths = [
        r'C:\Windows\Fonts\segoeuib.ttf',         # Segoe UI Bold
        r'C:\Windows\Fonts\arialbd.ttf',          # Arial Bold
        r'C:\Windows\Fonts\msyhbd.ttc',           # 微软雅黑 Bold
        r'C:\Windows\Fonts\simhei.ttf',           # 黑体
        r'C:\Windows\Fonts\arial.ttf',            # Arial
    ]
    font = None
    font_size = int(size * 0.55)
    for fp in font_paths:
        if os.path.exists(fp):
            try:
                font = ImageFont.truetype(fp, font_size)
                break
            except Exception:
                continue
    if font is None:
        font = ImageFont.load_default()

    # 计算 X 的中心位置
    text = 'X'
    bbox = draw.textbbox((0, 0), text, font=font)
    text_w = bbox[2] - bbox[0]
    text_h = bbox[3] - bbox[1]
    tx = (size - text_w) // 2 - bbox[0]
    ty = (size - text_h) // 2 - bbox[1]
    # 轻微下沉，居中看起来更稳
    ty -= int(size * 0.02)

    # X 加一点阴影（深一点的青绿）
    shadow_offset = max(1, size // 64)
    draw.text((tx + shadow_offset, ty + shadow_offset), text, fill=(6, 95, 70, 180), font=font)
    # 白色 X
    draw.text((tx, ty), text, fill=WHITE + (255,), font=font)

    return img


def save_android():
    for folder, size in ANDROID_SIZES.items():
        d = os.path.join(ANDROID_DIR, folder)
        os.makedirs(d, exist_ok=True)
        img = make_base(size)
        out = os.path.join(d, 'ic_launcher.png')
        img.save(out, 'PNG')
        print(f'  ✓ {folder}/ic_launcher.png ({size}x{size})')


def save_windows():
    base = make_base(WINDOWS_ICO)
    # ICO 内嵌多尺寸
    sizes_ico = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
    imgs = []
    for s in sizes_ico:
        im = base.resize(s, Image.LANCZOS)
        # PIL 保存 ICO 需要每个尺寸都是独立图像
        imgs.append(im)
    os.makedirs(os.path.dirname(WINDOWS_ICON), exist_ok=True)
    # 取最大的那张作为主图（其他尺寸 list）
    imgs[-1].save(
        WINDOWS_ICON,
        format='ICO',
        sizes=[(i.width, i.height) for i in imgs],
        append_images=imgs[:-1],
    )
    print(f'  ✓ windows/runner/resources/app_icon.ico (multi-size)')


if __name__ == '__main__':
    print('=== 生成 Android 启动图标 ===')
    save_android()
    print('=== 生成 Windows .ico ===')
    save_windows()
    print('完成。')