# -*- coding: utf-8 -*-
"""把门店的商品信息.txt 转成 App 内置商档 CSV。

源文件的真实形状（2026-09-19 实测，别猜）：
  · GBK 编码、制表符分隔、**没有表头**、67 列、126,890 行
  · 第 2 列(idx=1) 条码；第 3 列(idx=2) 商品名；第 17 列(idx=16) 售价

🔴 三个必须处理的脏数据（都是实测出来的，不是"以防万一"）：
  1. 8 行条码为空 → 跳过（导进去只会让员工扫到"未知商品"）
  2. 32 条条码是 '废' / '*****' 这类占位垃圾 → 条码不是纯数字的一律丢掉
  3. 少量售价为 -1 / 0 → 当空处理（否则盈亏表会算出负金额）

为什么**不带数量**：这份是商品主档，67 列里没有库存列（挨着看下来只有
进价/售价/税率/质量标准）。硬猜一列当账面数，猜错就是"账面=乱数"，
比留空（账面按 0 算、盈亏=实盘数）糟得多。要账面数得单独导一份库存表。

输出路径刻意用**纯 ASCII 文件名**（builtin_master.csv）：
aapt 对中文资源路径有坑（见 skill 坑 14），别给自己找事。
"""
import os
import sys

SRC = sys.argv[1] if len(sys.argv) > 1 else (
    r'D:\我的文档\微信聊天记录\xwechat_files\pblpan_278a\temp\RWTemp'
    r'\2026-09\d1bf52e493a49b524bc26de9866b73b5\商品信息.txt'
)
OUT = sys.argv[2] if len(sys.argv) > 2 else os.path.join(
    os.path.dirname(os.path.abspath(__file__)), '..', 'android', 'app', 'src',
    'hyd', 'assets', 'builtin_master.csv')

# ⚠️ 路径必须是 **android/app/src/hyd/assets/**，不是 android/src/...
#    build.gradle.kts 里的 sourceSets 写在 app 模块里，相对路径以
#    android/app/ 为基准。放错一层的话 gradle **不报错**、静默不打包 ——
#    2026-09-19 就踩了这个：APK 只大了 16KB，核验才发现档案根本没进包。

COL_BARCODE = 1
COL_NAME = 2
COL_PRICE = 16

def esc(v):
    s = str(v)
    if ',' in s or '"' in s or '\n' in s or '\r' in s:
        return '"' + s.replace('"', '""') + '"'
    return s

def main():
    raw = open(SRC, 'rb').read()
    text = raw.decode('gbk')
    lines = text.splitlines()

    out = ['\ufeff']  # BOM：万一有人拿 Excel 打开看
    out.append('序号,条码,商品名字,数量,售价\n')

    n = 0
    stat = {'empty_barcode': 0, 'junk_barcode': 0, 'bad_price': 0}
    seen = set()

    for line in lines:
        c = line.split('\t')
        if len(c) <= COL_BARCODE:
            continue
        barcode = c[COL_BARCODE].strip()
        if not barcode:
            stat['empty_barcode'] += 1
            continue
        # 纯数字才算条码：'废' / '*****' 这类是占位垃圾
        if not barcode.isdigit():
            stat['junk_barcode'] += 1
            continue
        name = c[COL_NAME].strip() if len(c) > COL_NAME else ''
        if not name:
            name = '未知商品'
        price = ''
        if len(c) > COL_PRICE:
            p = c[COL_PRICE].strip()
            try:
                f = float(p)
                if f > 0:
                    price = ('%g' % f)
                else:
                    stat['bad_price'] += 1
            except ValueError:
                stat['bad_price'] += 1
        if barcode in seen:      # 同条码只留第一条
            continue
        seen.add(barcode)
        n += 1
        out.append('%d,%s,%s,%s,%s\n' % (n, esc(barcode), esc(name), '', price))

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, 'w', encoding='utf-8', newline='') as f:
        f.write(''.join(out))

    print('输出:', OUT)
    print('写入商品: %d' % n)
    print('跳过: 空条码 %d / 垃圾条码 %d / 售价异常(置空) %d' % (
        stat['empty_barcode'], stat['junk_barcode'], stat['bad_price']))
    print('文件大小: %.1f MB' % (os.path.getsize(OUT) / 1024 / 1024))

if __name__ == '__main__':
    main()
