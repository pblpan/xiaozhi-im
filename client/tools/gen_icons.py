# -*- coding: utf-8 -*-
"""从一张源图生成**全端**应用图标（Android / Windows / 托盘 / iOS）。

用法：
    python tools/gen_icons.py <源图.png>
不给参数时用默认源图。

── 为什么要有这个脚本，而不是手工另存几遍 ────────────────────────
一次换图标要产出 5 个 Android 密度 + 一个多尺寸 .ico（Windows 窗口/任务栏 +
NSIS 安装包同用）+ 一个托盘 .ico + 15 个 iOS 尺寸。手搓必然漏，而且漏掉的
那一端要等**装到真机**上才看得出来（桌面快捷方式还是旧图标、托盘是默认图）。
脚本化以后换图 = 一条命令。

── 源图的两个坑（都必须处理，否则图标是坏的）────────────────────
① **白底没有透明通道**。设计稿是「白底 + 圆角方块」。直接把白底交出去：
   · 托盘/任务栏上是一个白方块（深色任务栏里非常显眼）；
   · Android 圆形 launcher 上被套一圈白。
   所以要把圆角方块**外面**的白变成透明。

② **方块内部有大量纯白像素（"小智IM"四个字）**。
   所以绝不能用「亮度 > 阈值就设透明」这种一刀切 —— 那样字会被掏空。
   这里的做法是**只从图像边界向内连续剥离背景**：逐行从左/右扫、逐列从上/下扫，
   遇到第一个非背景像素就停。圆角外侧的白被扫掉，方块中间的字因为四周都是
   蓝色，扫描线够不到它。这是本脚本唯一有点技巧的地方，改之前先想清楚。
"""
import io
import json
import os
import sys

from PIL import Image, ImageChops

HERE = os.path.dirname(os.path.abspath(__file__))
CLIENT = os.path.dirname(HERE)

DEFAULT_SRC = r'd:\Users\pblpa\Pictures\小智图标.png'
MASTER_OUT = os.path.join(HERE, 'icon_master_1024.png')   # 处理后的母版（不进包）

# 各密度边长（Flutter/Android 标准）
ANDROID = [('mdpi', 48), ('hdpi', 72), ('xhdpi', 96),
           ('xxhdpi', 144), ('xxxhdpi', 192)]
# Windows：窗口图标 + 任务栏 + NSIS 安装包共用这一个 .ico
WINDOWS_ICO = [16, 20, 24, 32, 40, 48, 64, 96, 128, 256]
# 托盘：小尺寸为主（Windows 托盘实际就用 16/20/24/32）
TRAY_ICO = [16, 20, 24, 32, 40, 48, 64]


def corner_bg(im):
    """取四角像素的中位色当背景色 —— 比硬写 (255,255,255) 稳，
    设计稿底色若带一点暖灰也不会判错。"""
    w, h = im.size
    xs = list(range(0, 5)) + list(range(w - 5, w))
    ys = list(range(0, 5)) + list(range(h - 5, h))
    pts = [im.getpixel((x, y)) for x in xs for y in ys]
    pts.sort(key=lambda c: sum(c))
    return pts[len(pts) // 2]


def content_bbox(im, bg, tol=30):
    """⚠️ 别用这个（留着说明为什么不用）。

    按「与背景色的差异」找边界，会把设计稿的**投影阴影**一起算成内容 ——
    实测：926x910 的图会给出 845x875 的框，底部一路到图片边缘，
    裁出来的图标四周留一圈透明、方块偏上，在 launcher 上显得"小一号"。
    """
    diff = ImageChops.difference(im, Image.new('RGB', im.size, bg)).convert('L')
    mask = diff.point(lambda v: 255 if v > tol else 0)
    return mask.getbbox()


def solid_bbox(im, sat_min=60):
    """按**饱和度**找实心图形的边界（真正该用的那个）。

    为什么是饱和度：投影阴影是低饱和的灰紫（实测 S≈27），
    而图标本体是高饱和的蓝紫渐变（S≈150+）。用饱和度一卡，
    阴影自然被排除，框正好落在圆角方块的边缘上 → 图标满幅。

    对比度/亮度都做不到这一点：浅蓝的方块亮度和白阴影很接近。
    """
    s = im.convert('HSV').getchannel('S')
    mask = s.point(lambda v: 255 if v > sat_min else 0)
    box = mask.getbbox()
    return box or (0, 0, im.size[0], im.size[1])


def to_rgba(im, bg, tol=90):
    """白底 → 透明。**只从边界向内连续剥离**，方块内部的白色文字不动。"""
    im = im.convert('RGB')
    w, h = im.size
    px = im.load()
    alpha = Image.new('L', (w, h), 255)
    ap = alpha.load()

    def dist(c):
        return max(abs(c[0] - bg[0]), abs(c[1] - bg[1]), abs(c[2] - bg[2]))

    # 逐行：左→右、右→左
    for y in range(h):
        x = 0
        while x < w and dist(px[x, y]) <= tol:
            ap[x, y] = int(255 * dist(px[x, y]) / tol)
            x += 1
        x = w - 1
        while x >= 0 and dist(px[x, y]) <= tol:
            ap[x, y] = int(255 * dist(px[x, y]) / tol)
            x -= 1
    # 逐列：上→下、下→上（行扫描够不到上下两条圆角）
    for x in range(w):
        y = 0
        while y < h and dist(px[x, y]) <= tol:
            ap[x, y] = int(255 * dist(px[x, y]) / tol)
            y += 1
        y = h - 1
        while y >= 0 and dist(px[x, y]) <= tol:
            ap[x, y] = int(255 * dist(px[x, y]) / tol)
            y -= 1

    out = im.convert('RGBA')
    out.putalpha(alpha)
    return out


def square(im, opaque_bg=None):
    """补成正方形（居中）。传 opaque_bg 则填不透明底色（iOS 用）。"""
    w, h = im.size
    s = max(w, h)
    fill = (opaque_bg + (255,)) if opaque_bg else (0, 0, 0, 0)
    out = Image.new('RGBA', (s, s), fill)
    out.paste(im, ((s - w) // 2, (s - h) // 2),
              im if im.mode == 'RGBA' else None)
    return out


def resize(im, size):
    """缩放 + **抹掉角上的残留 alpha**。

    LANCZOS 大幅缩小时会跨很多像素采样，把内圈的半透明像素混到四角 ——
    实测 48x48 的角上会留下 alpha≈16、72x72 是 ≈11 的纯白像素。
    16/255 ≈ 6%，深色背景上肉眼基本看不见，所以特别容易被当成"没问题"放过去；
    但图标就应该是干净的，而且这是**能一次改掉**的事。
    24/255 ≈ 9% 以下一律抹平（低于这个值的不是设计，是缩放噪声）。
    """
    out = im.resize((size, size), Image.LANCZOS)
    if out.mode == 'RGBA':
        a = out.getchannel('A').point(lambda v: 0 if v < 24 else v)
        out.putalpha(a)
    return out


def save_ico(im, path, sizes):
    """用**最大尺寸**的图做 base，让 Pillow 产出各尺寸帧（BMP 帧，兼容性最好）。

    ⚠️ 踩过的坑：写过一版 `frames[0].save(..., append_images=frames[1:])`，
    而 sizes 的第一个是 16 —— base 只有 16x16，结果 .ico 里**只剩一个 16 帧**、
    文件 757 字节（正常应该 ~140KB）。ICO 的 sizes 参数是从 base **缩小**，
    它不会放大，所以 base 必须给最大的那一张。

    ⚠️ 这条路径的角部清理我们管不到（Pillow 内部缩放照样会混进半透明像素）。
    实测残留 alpha ≈ 6%，深色背景上不可见，故核验只查"尺寸齐全"、不查角部。
    """
    big = resize(im, max(sizes))
    big.save(path, format='ICO', sizes=[(s, s) for s in sizes])
    return os.path.getsize(path)


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_SRC
    if not os.path.exists(src):
        raise SystemExit('源图不存在: %s' % src)

    raw = Image.open(src).convert('RGB')
    bg = corner_bg(raw)
    box = solid_bbox(raw)
    print('源图 %dx%d 背景色=%s 实心范围(按饱和度)=%s'
          % (raw.size[0], raw.size[1], bg, box))

    cropped = raw.crop(box)
    rgba = square(to_rgba(cropped, bg))
    print('处理后有内容区域 %s → 正方形 %dx%d' % (cropped.size, rgba.size[0], rgba.size[1]))

    master = resize(rgba, 1024)
    master.save(MASTER_OUT)
    print('母版(透明背景, 1024): %s' % MASTER_OUT)

    # ── Android ──────────────────────────────────────────────
    res = os.path.join(CLIENT, 'android', 'app', 'src', 'main', 'res')
    for d, s in ANDROID:
        p = os.path.join(res, 'mipmap-%s' % d, 'ic_launcher.png')
        resize(rgba, s).save(p)
        print('  android mipmap-%-8s %3dx%-3d %6dB  %s'
              % (d, s, s, os.path.getsize(p), os.path.basename(p)))

    # ── Windows（窗口 + 任务栏 + NSIS 安装包）────────────────
    win_ico = os.path.join(CLIENT, 'windows', 'runner', 'resources', 'app_icon.ico')
    n = save_ico(rgba, win_ico, WINDOWS_ICO)
    print('  windows app_icon.ico  %d 个尺寸 %6dB' % (len(WINDOWS_ICO), n))

    # ── 托盘 ─────────────────────────────────────────────────
    tray = os.path.join(CLIENT, 'assets', 'tray.ico')
    n = save_ico(rgba, tray, TRAY_ICO)
    print('  tray    assets/tray.ico %d 个尺寸 %6dB' % (len(TRAY_ICO), n))

    # ── iOS（图标**不能带透明**：透明区域会被填黑）────────────
    ios_dir = os.path.join(CLIENT, 'ios', 'Runner', 'Assets.xcassets',
                           'AppIcon.appiconset')
    cfg = os.path.join(ios_dir, 'Contents.json')
    if os.path.exists(cfg):
        data = json.load(io.open(cfg, encoding='utf-8'))
        ios_src = square(rgba, opaque_bg=(255, 255, 255))
        seen = set()
        for item in data.get('images', []):
            fn = item.get('filename')
            if not fn or fn in seen:
                continue
            seen.add(fn)
            size = float(item['size'].split('x')[0])
            scale = int(item['scale'].rstrip('x'))
            px = int(round(size * scale))
            ios_src.resize((px, px), Image.LANCZOS).convert('RGB').save(
                os.path.join(ios_dir, fn))
        print('  ios     AppIcon.appiconset %d 个尺寸（白底不透明）' % len(seen))
    else:
        print('  ios     没有 AppIcon.appiconset，跳过')

    # ── 自检：把最能说明问题的两件事量出来 ───────────────────
    chk = resize(rgba, 192)
    px = chk.load()
    corners = [px[0, 0][3], px[191, 0][3], px[0, 191][3], px[191, 191][3]]
    mid = px[96, 120]                      # 方块中部：应该有颜色、不透明
    print('\n自检：四角 alpha=%s（要接近 0=白底已去掉）；中部像素=%s alpha=%d'
          % (corners, mid[:3], mid[3]))
    return 0


if __name__ == '__main__':
    sys.exit(main())
