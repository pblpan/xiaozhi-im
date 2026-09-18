"""核验 Windows Setup exe：
1) 里面嵌的图标是不是新图（拿 app_icon.ico 的每帧字节去 exe 里找）
2) 版本资源里是不是当前版本（从 pubspec 现读）
3) integrity.dat 的两条哈希是不是和当前 Release 产物一致（改了就不可能一致）

用法：python tools/verify_win_setup.py [setup.exe 路径]
"""
import os
import re
import sys
import struct
import hashlib

SRC = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _version():
    with open(os.path.join(SRC, 'pubspec.yaml'), encoding='utf-8') as f:
        m = re.search(r'^version:\s*([0-9A-Za-z.+_-]+)', f.read(), re.M)
    return m.group(1).split('+')[0]


# 版本从 pubspec 现读，绝不写死（写死会在下次换版本时静默校验错对象）
VER = _version()
EXE = (sys.argv[1] if len(sys.argv) > 1 else
       r'D:\Users\pblpa\Desktop\小智 IM\小智IM-Setup-v%s.exe' % VER)
ICO = os.path.join(SRC, 'windows', 'runner', 'resources', 'app_icon.ico')
REL = os.path.join(SRC, 'build', 'windows', 'x64', 'runner', 'Release')

print('=' * 62)
print('Windows Setup 产物核验')
print('=' * 62)
print('exe :', EXE)
print('大小: %.1f MB' % (os.path.getsize(EXE) / 1048576))
data = open(EXE, 'rb').read()

# ---------- 1. 图标 ----------
print('\n[1] 图标核验')
ico = open(ICO, 'rb').read()
# 解析 ICO 目录，取每个帧的原始字节
cnt = struct.unpack_from('<H', ico, 4)[0]
frames = []
for i in range(cnt):
    off = 6 + i * 16
    w, h, ncol, res, planes, bpp, size, image_off = struct.unpack_from('<BBBBHHII', ico, off)
    w = w or 256
    h = h or 256
    frames.append((w, h, ico[image_off:image_off + size]))
print('  ico 帧数：', cnt, '尺寸：', sorted(set(f[0] for f in frames)))

hit = 0
for w, h, blob in frames:
    found = data.find(blob)
    mark = '✓ 在 exe 里找到' if found >= 0 else '（未找到，可能被 NSIS 重编码）'
    if found >= 0:
        hit += 1
    print('   %3dx%-3d %6d 字节  %s' % (w, h, len(blob), mark))
print('  → exe 内命中 %d/%d 帧' % (hit, cnt))
icon_ok = (hit == cnt)
print('  结论：', '新图标已完整打进安装包 ✓' if icon_ok else '有帧未命中，需改用 PE 资源解析再确认 ✗')

# ---------- 2. 版本 ----------
# NSIS 的 VIAddVersionKey 字符串以 UTF-16LE 存放在资源段，ASCII 形式搜不到是正常的，
# 所以只把「UTF-16 形式」当硬判据。
print('\n[2] 版本号核验（NSIS 版本资源是 UTF-16LE）')
checks = [
    ('UTF-16 版本 "%s"' % VER, VER.encode('utf-16-le'), True),
    ('UTF-16 应用名 "小智 IM"', '小智 IM'.encode('utf-16-le'), True),
    ('UTF-16 发布者 "潘坚强"', '潘坚强'.encode('utf-16-le'), False),
]
ver_ok = True
for label, needle, hard in checks:
    n = data.count(needle)
    if hard:
        ver_ok = ver_ok and n > 0
    print('   %-24s 命中 %2d 次 %s%s' % (label, n, '✓' if n else '✗',
                                        '' if hard else '（软指标，不计入结论）'))
print('  结论：', '安装包版本资源正确 ✓' if ver_ok else '版本资源不符 ✗')

# ---------- 3. 完整性清单 ----------
print('\n[3] integrity.dat 与实际产物比对')


def sha(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for chunk in iter(lambda: f.read(1 << 20), b''):
            h.update(chunk)
    return h.hexdigest()


stamp = os.path.join(REL, 'integrity.dat')
ok = False
if not os.path.exists(stamp):
    print('  ✗ 找不到 integrity.dat —— 安装包里的自校验清单缺失')
else:
    import json
    txt = open(stamp, 'rb').read().decode('utf-8', 'replace')
    obj = json.loads(txt)
    print('  清单内容：', json.dumps(obj, ensure_ascii=False))
    files = obj.get('files') or obj.get('hashes') or {}
    ok = True
    for rel, rec in files.items():
        real = os.path.join(REL, rel.replace('/', os.sep))
        if not os.path.exists(real):
            print('   ✗ %-30s 产物缺失' % rel)
            ok = False
            continue
        want = rec if isinstance(rec, str) else rec.get('sha256') or rec.get('hash')
        got = sha(real)
        same = (want or '').lower() == got
        ok = ok and same
        print('   %s %-30s 清单 %s… 实际 %s…' % ('✓' if same else '✗', rel,
                                                 (want or '')[:16], got[:16]))
    print('  结论：', '清单与产物一致 ✓（客户端启动校验能过）' if ok else '不一致 ✗（装完会被自己的完整性校验拦下）')
print('=' * 62)

sys.exit(0 if (icon_ok and ver_ok and ok) else 1)
