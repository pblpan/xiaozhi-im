#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
小智扫码枪 APK 产物核验（**在真实产物上实测命中**，不看源码）。

── 为什么必须做这一步 ──────────────────────────────────────────
2026-09-19 出过一次真事故：扫码列表 + 导出的代码写好了、单测全绿、`flutter analyze`
零问题，但**那个包根本没进任何构建**，龙哥装到手机上发现功能不存在。
从那以后定的规矩：交付前必须在产物里把"关键串"搜出来。
（见 skill `workbuddy-win-build-verify` 的原则：改动写完 ≠ 交付。）

── 两个必须记住的探针常识 ──────────────────────────────────────
1. **按产物的语言换编码**：
   · Dart 串（AOT 快照 libapp.so）：中文是 **UTF-16LE**；纯 ASCII 串是 UTF-8。
   · 原生串（classes.dex，Kotlin/Java 里的）：**UTF-8**。
   只搜一处会误判"代码没进包"。
2. **探针必须先拿"已知存在的串"校准**：先搜一个 100% 应该存在的
   （比如 App 名 / assets 里的文件），搜到了说明编码和姿势对；
   搜不到就先怀疑探针，不要直接下结论"功能没进包"。

用法：
    python tools/verify_apk.py build/app/outputs/flutter-apk/app-release.apk
"""
import io
import os
import re
import subprocess
import sys
import zipfile

# ── 探针目标 ────────────────────────────────────────────────────
# ⚠️ 只钉**不含插值的字面串**（或插值串里的字面片段）：
#    Dart 的 `'商档已导入：${n} 个商品'` 在快照里是
#    `'商档已导入：'` + 数字 + `' 个商品'` 三段，**整串永远搜不到**。
#    2026-09-19 就因为把带 `${}` 的源码原文当探针，白查了半天"为什么没进包"。
#    写探针时：从源码里挑 `'...'` 里没有 `$` 的那部分。
DART_PROBES = [
    ('App 名（校准用，必须命中）', '小智扫码枪', 'u16'),
    ('扫码页标题', '扫码枪', 'u16'),
    # ── 商档导入链路（这一版的核心新功能，四条分别对应链路的不同环节）──
    ('导入入口：菜单项', '导入商档 CSV', 'u16'),
    ('导入入口：按钮 tooltip', '商档（导入 CSV / 导出模板）', 'u16'),
    ('导入成功提示（插值串的前半段）', '商档已导入：', 'u16'),
    ('导入跳过行提示（插值串片段）', '条码为空', 'u16'),
    ('导入失败：空文件', '这个文件是空的', 'u16'),
    ('导入失败：读不到商品', '这份文件里没读到任何商品', 'u16'),
    ('模板文件名', '商档模板.csv', 'u16'),
    # ── 4 列商档（2026-09-19 改版）：表头列名 + 无表头兜底列序 ────
    # 命中不了 = 这一版模板没进包（员工拿到的还是旧的 6 列）。
    ('模板列名：商品名字', '商品名字', 'u16'),
    ('模板列名：数量', '数量', 'u16'),
    ('模板菜单项', '导出商档模板（照着填）', 'u16'),
    ('没有商档时的横幅', '还没有商品档案', 'u16'),
    # ── 扫码采集主链 ────────────────────────────────────────────
    ('空白列表的引导语', '还没有扫码记录', 'u16'),
    ('导出按钮：表格', '导出表格', 'u16'),
    ('盈亏表入口', '盈亏表', 'u16'),
    ('相机页兜底文案', '未知条码', 'u16'),
]

# GBK 码表探针（UTF-16LE）。这三段取自生成表里 0x81 / 0xB0 / 0xC9 三个 lead
# 各自的第 5~28 个已分配字符 —— 这种连续排列只可能出现在码表里，
# 命中了就说明 **GBK 表真的进了包**（没进的话 GBK CSV 会静默解成乱码）。
GBK_PROBES = [
    ('GBK 表 lead=0x81 段', '0f4e124e174e1f4e204e214e234e264e294e2e4e2f4e314e334e354e374e3c4e404e414e424e444e464e4a4e514e554e'),
    ('GBK 表 lead=0xB0 段', '49764a764b764e764f76507651765276537655765776587659765a765b765d765f766076617662766476657666766776'),
    ('GBK 表 lead=0xC9 段', '818483848484858486848a848d848f84908491849284938494849584968498849a849b849d849e849f84a084a284a384'),
]

# classes.dex（原生，UTF-8）
DEX_PROBES = [
    ('分享通道名（与 Dart 必须逐字一致）', 'xiaozhi/share'),
    ('分享面板标题', '发给同事'),
    ('FileProvider authority 后缀', '.sharefiles'),
]

# 必须**不在**包里的东西（砍依赖的证据）
MUST_NOT_HAVE_SO = [
    'libflutter_webrtc.so',   # WebRTC：通话用的，扫码枪不该有
    'libsqlite3.so',          # Android 走系统库（hooks 里 android: system）
]

# 🔴 我们**自己那份** AndroidManifest.xml 里绝不该出现的权限。
#
# 这一条查的是源码清单（可证伪、改坏了就红），**不是**合并后的清单 ——
# 合并后的清单里 INTERNET 一定在：它是 mobile_scanner 的 bundled MLKit
# 经 com.google.android.datatransport:transport-backend-cct 带进来的。
# 把它写成"合并清单里不该有 INTERNET"就是一条**永远红的断言**，
# 而永远红的告警比没有告警更糟（真出问题没人看）。
SOURCE_MANIFEST_FORBIDDEN = [
    'android.permission.INTERNET',      # 代码一次网络请求都不发
    'android.permission.RECORD_AUDIO',  # 录音：IM 的功能
    'android.permission.READ_EXTERNAL_STORAGE',
]
REQUIRED_PERMISSIONS = [
    'android.permission.CAMERA',
    'android.permission.VIBRATE',
]

# 已知会被**依赖**注入到合并清单里的权限（信息性，不作为通过/失败判据）。
# 记下来的意义：下次看到"这个 App 怎么要网络权限"能立刻答上来，
# 而不是从头去翻 manifest-merger 报告。
KNOWN_INJECTED = {
    'android.permission.INTERNET':
        'com.google.android.datatransport:transport-backend-cct（bundled MLKit 的传递依赖）',
    'android.permission.ACCESS_NETWORK_STATE': '同上（MLKit 遥测）',
    'android.permission.READ_EXTERNAL_STORAGE': 'open_filex（用 FileProvider 打开文件，运行时不申请）',
    'android.permission.READ_MEDIA_IMAGES': 'open_filex',
    'android.permission.READ_MEDIA_VIDEO': 'open_filex',
    'android.permission.READ_MEDIA_AUDIO': 'open_filex',
    # 这条不是谁"声明"的，是 androidx 按需自动加的（Android 14 对
    # 动态注册广播接收器的要求）。标出来免得被当成可疑权限。
    'com.pblpan.xiaozhi_scanner.DYNAMIC_RECEIVER_NOT_EXPORTED_PERMISSION':
        'androidx 自动生成（Android 14 动态广播接收器要求）',
}


def check_source_manifest(repo_root):
    """查我们自己的 AndroidManifest.xml（源码），返回 (ok, 详情列表)。"""
    path = os.path.join(repo_root, 'android', 'app', 'src', 'main', 'AndroidManifest.xml')
    if not os.path.isfile(path):
        return False, ['找不到源码清单：%s' % path]
    with io.open(path, encoding='utf-8') as f:
        # 注释里会提到这些权限名（说明为什么不能加），所以要把注释剥掉再查
        text = re.sub(r'<!--.*?-->', '', f.read(), flags=re.S)
    details = []
    ok = True
    for p in SOURCE_MANIFEST_FORBIDDEN:
        if '<uses-permission android:name="%s"' % p in text:
            details.append('  ❌ 源码清单声明了 %s（不该有）' % p)
            ok = False
        else:
            details.append('  ✅ 源码清单没声明 %s' % p)
    return ok, details


def find_sdk_aapt():
    """在 android-sdk/build-tools/*/ 里找 aapt.exe（优先最新版本）。"""
    sdk = os.environ.get('ANDROID_SDK_ROOT') or os.environ.get('ANDROID_HOME')
    if not sdk:
        return None
    bt = os.path.join(sdk, 'build-tools')
    if not os.path.isdir(bt):
        return None
    for name in sorted(os.listdir(bt), reverse=True):
        exe = os.path.join(bt, name, 'aapt.exe')
        if os.path.isfile(exe):
            return exe
        exe = os.path.join(bt, name, 'aapt')
        if os.path.isfile(exe):
            return exe
    return None


def aapt_badging(apk):
    """用 aapt 读 APK 清单。拿不到 aapt 就返回 None（下面的解析会降级）。"""
    aapt = find_sdk_aapt()
    if not aapt:
        return None
    try:
        out = subprocess.run([aapt, 'dump', 'badging', apk],
                             capture_output=True)
        return out.stdout.decode('utf-8', 'replace')
    except Exception:
        return None


def search_manifest_in_zip(apk, text):
    """没有 aapt 时的降级：直接扫 AndroidManifest.xml 的原始字节（UTF-16LE）。
    ⚠️ 二进制 XML 里字符串是 UTF-16LE，且**长度前缀是字符数**（不是字节数），
    所以只能做"包含"判断，不能精确定位。够用来判断权限/标签在不在。
    """
    with zipfile.ZipFile(apk) as z:
        data = z.read('AndroidManifest.xml')
    return data


def main():
    if len(sys.argv) < 2:
        sys.stderr.write('usage: verify_apk.py <apk>\n')
        return 2
    apk = sys.argv[1]
    if not os.path.isfile(apk):
        sys.stderr.write('APK 不存在: %s\n' % apk)
        return 2

    ok = True
    note = []

    with zipfile.ZipFile(apk) as z:
        names = z.namelist()
        libapp = z.read('lib/arm64-v8a/libapp.so') if 'lib/arm64-v8a/libapp.so' in names else None
        if libapp is None:
            # 有些包 ABI 目录不同，找一个存在的
            for n in names:
                if n.endswith('/libapp.so'):
                    libapp = z.read(n)
                    note.append('libapp.so 取自 %s' % n)
                    break
        dex_all = b''.join(z.read(n) for n in names
                           if re.match(r'classes\d*\.dex$', n))

        print('=' * 68)
        print('APK: %s' % apk)
        print('大小: %.1f MB   条目: %d' % (os.path.getsize(apk) / 1048576.0, len(names)))
        print('=' * 68)

        # ── 1) 声音资源 ──────────────────────────────────────────
        print('\n[1] 扫码反馈音效（少了 = 扫成功没声音，龙哥的第一条报障）')
        for snd in ('assets/flutter_assets/assets/sounds/scan_ok.wav',
                    'assets/flutter_assets/assets/sounds/scan_fail.wav'):
            hit = snd in names
            print('  %-58s %s' % (snd, 'OK' if hit else '缺失 <<<'))
            ok = ok and hit

        # ── 2) 依赖砍干净了吗 ───────────────────────────────────
        print('\n[2] 被砍掉的依赖不该出现在包里')
        sos = [n for n in names if n.endswith('.so')]
        for bad in MUST_NOT_HAVE_SO:
            hit = any(n.endswith('/' + bad) for n in names)
            print('  %-40s %s' % (bad, '在包里 <<< 不该有' if hit else 'OK(不在)'))
            ok = ok and (not hit)
        print('  包内 .so 共 %d 个：%s' % (len(sos), ', '.join(sorted(set(os.path.basename(s) for s in sos)))))
        print('  bulk MLKit 证据（bundled 版才有）：%s'
              % ('OK' if any('barhopper' in n for n in sos) else '没有！unbundled 版在国产机上扫不出 <<<'))

        # ── 3) Dart 侧关键串（UTF-16LE）─────────────────────────
        print('\n[3] Dart 侧关键串（libapp.so，UTF-16LE）')
        if libapp is None:
            print('  找不到 libapp.so <<<')
            ok = False
        else:
            for label, s, enc in DART_PROBES:
                needle = s.encode('utf-16-le')
                hit = needle in libapp
                print('  %-38s %s' % (label, 'OK' if hit else '未命中 <<<'))
                ok = ok and hit
            print('  -- GBK 码表 --')
            for label, hexs in GBK_PROBES:
                needle = bytes.fromhex(hexs)
                hit = needle in libapp
                print('  %-38s %s' % (label, 'OK' if hit else '未命中 <<<'))
                ok = ok and hit

        # ── 4) 原生侧关键串（classes.dex，UTF-8）────────────────
        print('\n[4] 原生侧关键串（classes.dex，UTF-8）')
        for label, s in DEX_PROBES:
            hit = s.encode('utf-8') in dex_all
            print('  %-38s %s' % (label, 'OK' if hit else '未命中 <<<'))
            ok = ok and hit

        # ── 5) 清单：包名 / 应用名 / 权限 ───────────────────────
        print('\n[5] AndroidManifest：包名 / 应用名 / 权限')
        badging = aapt_badging(apk)
        if badging:
            for line in badging.splitlines():
                if line.startswith('package:') or line.startswith('application-label:'):
                    print('  ' + line)
            perms = re.findall(r"uses-permission: name='([^']+)'", badging)
            for p in REQUIRED_PERMISSIONS:
                hit = p in perms
                print('  需要 %-40s %s' % (p, 'OK' if hit else '缺失 <<<'))
                ok = ok and hit
            print('  合并后的全部权限（信息性）：')
            for p in sorted(perms):
                src = KNOWN_INJECTED.get(p)
                print('    %-52s %s' % (p, ('← 依赖注入：' + src) if src else '← 本工程声明'))
        else:
            print('  ⚠️ 找不到 aapt，降级为直接扫清单字节')
            mf = search_manifest_in_zip(apk, None)
            for p in REQUIRED_PERMISSIONS:
                hit = p.encode('utf-16-le') in mf
                print('  %-44s %s' % (p, '在清单里 OK' if hit else '缺 <<<'))
                ok = ok and hit
            label = '小智扫码枪'.encode('utf-16-le') in mf
            print('  %-44s %s' % ('应用名「小智扫码枪」', 'OK' if label else '未命中 <<<'))
            ok = ok and label

        # ── 6) 我们自己的源码清单里不许有那几个权限 ──────────────
        print('\n[6] 源码 AndroidManifest.xml（我们声明的，不是合并后的）')
        repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        s_ok, details = check_source_manifest(repo_root)
        for d in details:
            print(d)
        ok = ok and s_ok
        print('  （INTERNET 等是依赖合并进来的，见 [5] 的标注；'
              '合并不等于我们声明，这条查的是后者）')

    print('\n' + '=' * 68)
    if note:
        for n in note:
            print('note: %s' % n)
    print('结论：%s' % ('全部命中 ✅' if ok else '有未命中项 ❌（见上面的 <<<）'))
    print('=' * 68)
    return 0 if ok else 1


if __name__ == '__main__':
    raise SystemExit(main())
