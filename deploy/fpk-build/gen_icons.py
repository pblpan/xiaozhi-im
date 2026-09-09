# -*- coding: utf-8 -*-
"""生成小智 IM 品牌图标（渐变靛紫 + 聊天气泡）—— 供 fpk 打包脚本调用"""
from PIL import Image, ImageDraw
import os

def draw_icon(size, path):
    S = size * 4
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    R = S * 0.22
    c1 = (91, 116, 245)
    c2 = (157, 91, 245)
    for y in range(S):
        t = y / (S - 1)
        r = int(c1[0] + (c2[0] - c1[0]) * t)
        g = int(c1[1] + (c2[1] - c1[1]) * t)
        b = int(c1[2] + (c2[2] - c1[2]) * t)
        mask = Image.new("L", (S, S), 0)
        ImageDraw.Draw(mask).rounded_rectangle([0, 0, S - 1, S - 1], radius=R, fill=255)
        line = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        ImageDraw.Draw(line).line([(0, y), (S, y)], fill=(r, g, b, 255), width=1)
        img.paste(line, (0, 0), mask)
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, S - 1, S - 1], radius=R, outline=(255, 255, 255, 90), width=max(1, int(S * 0.012)))
    bw, bh = S * 0.62, S * 0.42
    bx, by = (S - bw) / 2 - S * 0.02, (S - bh) / 2 - S * 0.03
    d.rounded_rectangle([bx, by, bx + bw, by + bh], radius=bh * 0.35, fill=(255, 255, 255, 255))
    tx, ty = bx + bw * 0.22, by + bh - 1
    d.polygon([(tx, ty - 1), (tx + S * 0.055, ty + S * 0.075), (tx + S * 0.09, ty)], fill=(255, 255, 255, 255))
    lx0 = bx + bw * 0.16
    lw = bw * 0.68
    ly0 = by + bh * 0.30
    line_h = bh * 0.12
    gap = bh * 0.22
    lc = (140, 120, 245)
    for i in range(3):
        y = ly0 + i * gap
        ln = lw * (1.0 - i * 0.22)
        d.rounded_rectangle([lx0, y - line_h / 2, lx0 + ln, y + line_h / 2], radius=line_h * 0.6, fill=lc)
    img = img.resize((size, size), Image.LANCZOS)
    img.save(path)
    print("saved", path, size)

if __name__ == "__main__":
    base = os.path.dirname(os.path.abspath(__file__))
    draw_icon(512, os.path.join(base, "ICON.PNG"))
    draw_icon(256, os.path.join(base, "ICON_256.PNG"))
    draw_icon(256, os.path.join(base, "app", "ui", "images", "icon-256.png"))
    draw_icon(64, os.path.join(base, "app", "ui", "images", "icon-64.png"))
