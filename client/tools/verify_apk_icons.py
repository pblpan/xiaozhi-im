"""核验 APK 内 launcher 图标 = 源码图标。

⚠️ 血泪教训：不能用 `ImageChops.difference(a,b).getbbox() is None` 判一致。
   两张 RGBA 相减，A 通道差恒为 0；而 getbbox() 要求**所有通道**同时非零才算
   "有内容"，于是永远返回 None → 断言恒真、永远"通过"。
   PNG 里 alpha=0 的像素其 RGB 是垃圾值，AAPT2 无损压缩会把它们归零，
   所以逐字节/逐通道全比也必然"不一致"，那是假失败。
   正确判据：**只在 alpha>0 的像素上比 RGB**。
   注意 AAPT2 也不做有损压缩，但 CRC 会变，所以不能比 sha256。
"""
import io
import os
import re
import subprocess
import sys
import zipfile

from PIL import Image

SRC = r'C:\Users\pblpa\WorkBuddy\2026-09-08-11-01-42\xiaozhi-im\client'
RES = os.path.join(SRC, 'android', 'app', 'src', 'main', 'res')
AAPT = (r'C:\Users\pblpa\WorkBuddy\2026-09-08-11-01-42\tools\android-sdk'
        r'\build-tools\36.0.0\aapt.exe')
DPI2DIR = {'160': 'mipmap-mdpi', '240': 'mipmap-hdpi', '320': 'mipmap-xhdpi',
           '480': 'mipmap-xxhdpi', '640': 'mipmap-xxxhdpi'}


def _apk_path():
    """版本从 pubspec 现读，绝不写死（写死会在下次换版本时静默去验上一个包）。"""
    with open(os.path.join(SRC, 'pubspec.yaml'), encoding='utf-8') as f:
        m = re.search(r'^version:\s*([0-9A-Za-z.+_-]+)', f.read(), re.M)
    ver = m.group(1).split('+')[0]
    return (sys.argv[1] if len(sys.argv) > 1 else
            r'D:\Users\pblpa\Desktop\小智 IM\小智IM-Android-v%s.apk' % ver)


APK = _apk_path()


def compare(a, b):
    """只比可见像素。返回 (可见像素数, 不一致数, 样例)"""
    pa = list(a.convert('RGBA').get_flattened_data())
    pb = list(b.convert('RGBA').get_flattened_data())
    if len(pa) != len(pb):
        return 0, -1, '尺寸不同'
    visible = 0
    bad = 0
    sample = ''
    for x, y in zip(pa, pb):
        if x[3] != y[3]:
            bad += 1
            if not sample:
                sample = 'alpha 不同: %s vs %s' % (x, y)
            continue
        if x[3] == 0:
            continue          # 完全透明 —— RGB 是垃圾值，不参与比较
        visible += 1
        if (x[0], x[1], x[2]) != (y[0], y[1], y[2]):
            bad += 1
            if not sample:
                sample = 'RGB 不同: %s vs %s' % (x, y)
    return visible, bad, sample


def main():
    print('=' * 70)
    print('APK 内图标核验（正确判据：只在 alpha>0 的像素上比 RGB）')
    print('=' * 70)

    # aapt 不吃中文路径（Illegal byte sequence）→ 先在 ASCII 路径下拿资源名
    import os
    import shutil
    tmp = os.path.join(os.environ.get('TEMP', '.'), 'xz_icon_v')
    os.makedirs(tmp, exist_ok=True)
    ascii_apk = os.path.join(tmp, 'a.apk')
    shutil.copyfile(APK, ascii_apk)

    out = subprocess.run([AAPT, 'dump', 'badging', ascii_apk],
                         capture_output=True, text=True, errors='replace').stdout
    ver = re.search(r"versionCode='(\d+)' versionName='([^']+)'", out)
    print('包版本: %s' % ((ver.groups(),) if ver else ('读不到',)))
    icons = dict(re.findall(r"application-icon-(\d+):'([^']+)'", out))
    print('launcher 图标条目: %d 个' % len(icons))
    print()

    z = zipfile.ZipFile(ascii_apk)
    all_ok = True
    for dpi in sorted(icons, key=int):
        res = icons[dpi]
        loc = DPI2DIR.get(dpi)
        if not loc:
            print('  ? %s %s （未知 dpi，跳过）' % (dpi, res))
            continue
        pkg = Image.open(io.BytesIO(z.read(res)))
        src = Image.open(os.path.join(RES, loc, 'ic_launcher.png'))
        vis, bad, sample = compare(pkg, src)
        ok = (bad == 0)
        all_ok = all_ok and ok
        al = pkg.convert('RGBA').getchannel('A').getextrema()
        print('  %s %-4s %-12s %-9s 可见像素=%d 不一致=%d alpha=%s'
              % ('✓' if ok else '✗', dpi, res, '%dx%d' % pkg.size, vis, bad, '%s' % (al,)))
        if not ok:
            print('       %s' % sample)

    shutil.rmtree(tmp, ignore_errors=True)
    print()
    print('结论：%s' % ('APK 内图标 = 源码新图标（可见像素零差异）✓'
                      if all_ok else '存在可见像素差异 ✗ —— 需要人工看图确认'))
    return 0 if all_ok else 1


if __name__ == '__main__':
    sys.exit(main())
