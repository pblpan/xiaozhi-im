# -*- coding: utf-8 -*-
"""生成小智 IM 品牌图标 —— 供 fpk 打包脚本调用

⚠️ 这里**不再自己画图标**。老版本用 PIL 画"渐变圆角 + 聊天气泡"，
   实际画出来是**白底 + 三条紫色横线**（气泡轮廓在缩放后完全糊掉），
   而飞牛桌面/应用中心用的就是这套 —— 客户看到的是个"三横线"而不是小智 IM。
   更坑的是 build.sh 只在 ICON.PNG 不存在时才调本脚本，所以这套错图标
   从 2026-09-09 起一直躺在包里，谁也没发现。

现在只有一个源头：client/tools/icon_master_1024.png（1024×1024 品牌母版）。
所有尺寸都是它的等比缩放 —— 图标不可能再和 App/客户端不一致。

用法：python deploy/fpk-build/gen_icons.py
"""
import os
import sys

try:
    from PIL import Image
except ImportError:
    sys.exit("需要 Pillow：pip install pillow")

BASE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(BASE, "..", ".."))
MASTER = os.path.join(ROOT, "client", "tools", "icon_master_1024.png")

# 输出清单：(尺寸, 目标路径)
#
# 🔴 2026-10-12 修"桌面图标显示错误"：
#   app/ui/config 的图标模板是 `images/icon-{0}.png`（**连字符**，{0}=尺寸）。
#   以前这里只生成连字符文件名 —— 看似对得上，但 config 当年是从 scaffold
#   带过来的**下划线**模板 `icon_{0}.png`，两边不一致 → 飞牛按模板找
#   `icon_256.png` 而磁盘上只有 `icon-256.png` → 桌面图标变成"错误/占位"图。
#   现在：连字符 + 下划线**两套都出**（工厂V2/餐饮就是这么做的，最稳），
#   外加一个无尺寸的 `icon.png` 兜底。config 已同步改成连字符模板。
_IMG = os.path.join(BASE, "app", "ui", "images")
TARGETS = [
    (512, os.path.join(BASE, "ICON.PNG")),                       # fpk 包根图标
    (256, os.path.join(BASE, "ICON_256.PNG")),                   # fnpack 清单用
    (256, os.path.join(_IMG, "icon-256.png")),                   # 飞牛桌面大图标（连字符）
    (64, os.path.join(_IMG, "icon-64.png")),                     # 飞牛列表小图标（连字符）
    (256, os.path.join(_IMG, "icon_256.png")),                   # 同上的下划线副本（兼容）
    (64, os.path.join(_IMG, "icon_64.png")),                     # 同上的下划线副本（兼容）
    (256, os.path.join(_IMG, "icon.png")),                       # 无尺寸兜底
]


def main():
    if not os.path.isfile(MASTER):
        # 硬失败，不退化成"随便画一个"。历史上就是因为有兜底，错图标才混进包里的。
        sys.exit("品牌母版不存在：%s\n"
                 "（图标必须从这个文件缩放，不要另画一套。）" % MASTER)

    src = Image.open(MASTER)
    src.load()
    if src.width != src.height or src.width < 512:
        sys.exit("母版必须是正方形且 >= 512px，实际 %dx%d" % (src.width, src.height))
    src = src.convert("RGBA")
    print("母版: %s  %dx%d" % (MASTER, src.width, src.height))

    for size, dst in TARGETS:
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        img = src.resize((size, size), Image.LANCZOS)
        img.save(dst)
        print("  -> %-52s %dx%d  %d bytes" % (
            os.path.relpath(dst, ROOT).replace("\\", "/"), size, size,
            os.path.getsize(dst)))
    print("图标全部由母版缩放生成（%d 个，含连字符/下划线两套桌面图标）" % len(TARGETS))


if __name__ == "__main__":
    main()
