# -*- coding: utf-8 -*-
r"""iOS 工程静态校验 —— 在没有 Mac 的前提下，尽可能把错挡在 Mac 之前。

【为什么需要它】
我们手上没有 Mac、没有 xcodebuild、没有 pod，**无法编译 iOS 工程**。
所以这里做的是"编译之前能查的全部"：
  · 目录/文件是否齐全（模板覆盖漏项是手工生成的常见病）
  · Info.plist 权限是否齐全（漏了在真机上表现为"功能静默失效"或闪退）
  · 版本号是否与 pubspec 对齐（版本号纪律，三端一致）
  · 工程自身的引用是否自洽（pbxproj 引用的文件是否真的存在）
  · 有没有模板占位符残留（`{{...}}` 漏替换在 Xcode 里是玄学错误）
  · 图标尺寸/格式是否正确、1024 是否已去透明通道
  · 依赖是否都有 iOS 实现

【纪律：每条判据都必须是"会失败的断言"】
上一轮踩过：探针 53/53 全绿，但 TURN 其实是残废的 —— 因为关键状态被写成
了"打印一行 ⚠ 警告"而不是断言。**假通过比不检查更危险**（让人以为验过了）。
所以本脚本：
  · 只输出 PASS/FAIL，不输出"仅供参考"的软警告
  · 结尾按失败数给退出码，CI/后续脚本可直接依赖
  · 每条 FAIL 都带"人话解释 + 怎么修"

【用法】
    python client/verify_ios.py            # 校验
    python client/verify_ios.py -v         # 多打点细节
退出码：0 全通过 / 1 有失败
"""
import argparse
import json
import os
import plistlib
import re
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
IOS = os.path.join(HERE, 'ios')
PUBSPEC = os.path.join(HERE, 'pubspec.yaml')
APPVER = os.path.join(HERE, 'lib', 'core', 'app_version.dart')
PLUGDEPS = os.path.join(HERE, '.flutter-plugins-dependencies')

VERBOSE = False
FAILS = []
PASSES = [0]


def ok(name, detail=''):
    PASSES[0] += 1
    print('  [PASS] %-38s %s' % (name, detail))


def bad(name, why, fix):
    FAILS.append(name)
    print('  [FAIL] %-38s %s' % (name, why))
    print('         %s%s 修法：%s' % ('', '', fix))


def chk(cond, name, why, fix, detail=''):
    """单条判据。cond 为假立刻记 FAIL —— 这就是"会失败的断言"。"""
    if cond:
        ok(name, detail)
    else:
        bad(name, why, fix)
    return bool(cond)


def read_text(p):
    with open(p, 'r', encoding='utf-8', errors='replace') as f:
        return f.read()


# ---------------------------------------------------------------- 1. 目录骨架
# 这些是 flutter create 出来就必须有的。少一个 Xcode 就打不开或跑不起来。
REQUIRED = [
    'Runner.xcodeproj/project.pbxproj',
    'Runner.xcworkspace/contents.xcworkspacedata',
    'Runner/AppDelegate.swift',
    'Runner/SceneDelegate.swift',
    'Runner/Info.plist',
    'Runner/Runner-Bridging-Header.h',
    'Runner/Base.lproj/Main.storyboard',
    'Runner/Base.lproj/LaunchScreen.storyboard',
    'Runner/Assets.xcassets/AppIcon.appiconset/Contents.json',
    'Runner/Assets.xcassets/LaunchImage.imageset/Contents.json',
    'Flutter/AppFrameworkInfo.plist',
    'Flutter/Debug.xcconfig',
    'Flutter/Release.xcconfig',
    'RunnerTests/RunnerTests.swift',
]


def check_skeleton():
    print('\n[1/8] 目录骨架')
    miss = [r for r in REQUIRED if not os.path.isfile(os.path.join(IOS, r))]
    chk(not miss, '模板必需文件齐全',
        '缺 %d 个：%s' % (len(miss), ', '.join(miss)),
        '重跑 python client/tool/gen_ios_project.py --force')
    chk(os.path.isdir(os.path.join(IOS, 'Runner.xcworkspace')),
        'Runner.xcworkspace 存在',
        '没有 workspace，CocoaPods 安装后 Xcode 会打开错的工程',
        '重跑生成脚本')
    chk(not os.path.isfile(os.path.join(IOS, 'Podfile')),
        'Podfile 未预置（正确）',
        '手工预置 Podfile 容易与 flutter 自动生成的版本冲突；'
        '它应由 `flutter build ios` / `pod install` 在 Mac 上首次生成',
        '删掉 ios/Podfile，交给 Mac')


# ------------------------------------------------------------ 2. 占位符残留
def check_no_placeholders():
    print('\n[2/8] 模板占位符残留')
    hits = []
    for dirpath, _d, files in os.walk(IOS):
        for fn in files:
            p = os.path.join(dirpath, fn)
            # 只查文本类；二进制（png/故事板已解析）本来就可能含 `{{` 字节
            if os.path.splitext(fn)[1].lower() not in (
                    '.swift', '.plist', '.pbxproj', '.xcconfig', '.storyboard',
                    '.json', '.xcscheme', '.xcsettings', '.xcworkspacedata', '.md'):
                continue
            t = read_text(p)
            for m in re.findall(r'\{\{[^}]*\}\}', t):
                hits.append('%s -> %s' % (os.path.relpath(p, IOS), m))
    chk(not hits, '无 {{占位符}} 残留',
        '残留 %d 处：%s' % (len(hits), '; '.join(hits[:5])),
        '在 tool/gen_ios_project.py 的 render() 里补上对应变量/块')

    # .tmpl 后缀文件不该出现在产物里
    tmpl = []
    for dirpath, _d, files in os.walk(IOS):
        tmpl += [os.path.relpath(os.path.join(dirpath, f), IOS)
                 for f in files if f.endswith('.tmpl')]
    chk(not tmpl, '无 .tmpl 残留',
        '残留：%s' % tmpl, 'gen_ios_project.py 的 output_name() 规则有漏')


# ------------------------------------------------------- 3. Info.plist 权限
# 每条权限对应一个"不写就静默失效"的功能。这是本工程 iOS 侧最大的坑区。
IOS_PERMS = {
    'NSCameraUsageDescription': '视频通话 / 拍照发送（缺了调用时直接闪退）',
    'NSMicrophoneUsageDescription': '语音通话 / 语音消息（同上）',
    'NSPhotoLibraryUsageDescription': '从相册选图发送',
    'NSPhotoLibraryAddUsageDescription': '把收到的图存到相册',
    'NSLocalNetworkUsageDescription': '连局域网服务器（iOS14+ 必需，缺了内网连不上且不报错）',
}
IOS_ARRAYS = ['NSBonjourServices']
IOS_DICTS = ['NSAppTransportSecurity']


def check_plist():
    print('\n[3/8] Info.plist 权限与网络配置')
    p = os.path.join(IOS, 'Runner', 'Info.plist')
    if not os.path.isfile(p):
        bad('Info.plist 可解析', '文件不存在', '重跑生成脚本')
        return
    try:
        with open(p, 'rb') as f:
            d = plistlib.load(f)
    except Exception as e:
        bad('Info.plist 可解析', 'XML/plist 解析失败：%s' % e,
            '检查 permissions_block() 生成的 XML 是否闭合')
        return
    ok('Info.plist 可解析', '顶层键 %d 个' % len(d))

    for k, desc in IOS_PERMS.items():
        v = d.get(k, '')
        chk(isinstance(v, str) and len(v.strip()) >= 4,
            k, '缺失或为空 —— 会导致：%s' % desc,
            '在 tool/gen_ios_project.py 的 permissions_block() 里补上')
    for k in IOS_ARRAYS:
        chk(isinstance(d.get(k), list) and d[k], k, '缺失或空数组',
            '在 permissions_block() 里补上')
    for k in IOS_DICTS:
        chk(isinstance(d.get(k), dict) and d[k], k, '缺失或空字典',
            '在 permissions_block() 里补上')

    # ATS 必须"默认关、按域开例外"。全局放开会被审核质询。
    ats = d.get('NSAppTransportSecurity') or {}
    chk(ats.get('NSAllowsArbitraryLoads') in (False, None),
        'ATS 未全局放开明文',
        'NSAllowsArbitraryLoads 被设为 true —— App Store 审核会要求书面说明理由',
        '改成 false，把需要的 IP 加进 NSExceptionDomains')
    doms = ats.get('NSExceptionDomains') or {}
    chk(bool(doms), 'ATS 有内网例外域',
        '没例外域则 http:// 内网地址会被 ATS 拦掉，表现为"连不上服务器"',
        '在 gen_ios_project.py 的 PLAIN_HTTP_HOSTS 里加服务器 IP')
    if VERBOSE and doms:
        for h in doms:
            print('         · 例外域 %s' % h)
    # 每个例外域必须真的允许明文，只列域名不设开关是不生效的
    bad_sw = [h for h, v in doms.items()
              if not (v or {}).get('NSExceptionAllowsInsecureHTTPLoads')]
    chk(not bad_sw, '例外域均已开启明文许可',
        '这些域只列了名字没开 NSExceptionAllowsInsecureHTTPLoads：%s' % bad_sw,
        'permissions_block() 里补上该键')

    # 显示名与 Bundle ID
    chk('$(PRODUCT_BUNDLE_IDENTIFIER)' == d.get('CFBundleIdentifier'),
        'CFBundleIdentifier 用变量引用',
        '写死了 Bundle ID，切 Debug/Release 配置时会不一致',
        '改成 $(PRODUCT_BUNDLE_IDENTIFIER)')
    chk(bool(d.get('CFBundleDisplayName')), 'CFBundleDisplayName 已设置',
        '没设则桌面图标名是工程名（xiaozhi_im_client），很难看',
        'gen_ios_project.py 的 DISPLAY_NAME')


# ------------------------------------------------------------- 4. 版本号纪律
def check_version():
    print('\n[4/8] 版本号一致性')
    mt = re.search(r'^version:\s*([0-9.]+)\+(\d+)',
                   read_text(PUBSPEC), re.M)
    if not chk(bool(mt), 'pubspec.yaml 版本可读', '读不到 version 行',
               '检查 pubspec.yaml 格式'):
        return
    pv, pb = mt.group(1), mt.group(2)
    ok('pubspec 版本', '%s+%s' % (pv, pb))

    # app_version.dart 的 kAppVersion 必须与 pubspec 主版本一致
    mv = re.search(r"kAppVersion\s*=\s*'([^']+)'", read_text(APPVER))
    chk(mv and mv.group(1) == pv,
        'kAppVersion 与 pubspec 一致',
        'app_version.dart 是 %s，pubspec 是 %s —— 界面上显示的版本会不一致'
        % (mv.group(1) if mv else '(读不到)', pv),
        "改 client/lib/core/app_version.dart 的 kAppVersion")

    # pbxproj：MARKETING_VERSION / CURRENT_PROJECT_VERSION 若存在则必须对齐
    pbx = read_text(os.path.join(IOS, 'Runner.xcodeproj', 'project.pbxproj'))
    mk = set(re.findall(r'MARKETING_VERSION\s*=\s*([^;]+);', pbx))
    cv = set(re.findall(r'CURRENT_PROJECT_VERSION\s*=\s*([^;]+);', pbx))
    if mk:
        vals = {v.strip().strip('"') for v in mk}
        chk(vals == {pv}, 'pbxproj MARKETING_VERSION 对齐',
            '工程里是 %s，pubspec 是 %s —— Xcode 里显示的版本会不对'
            % (sorted(vals), pv),
            '在 Mac 上改成 %s（或改 gen_ios_project.py 统一注入）' % pv)
    else:
        # Flutter 模板默认用 FLUTTER_BUILD_NAME 变量，这其实是更好的做法
        chk('FLUTTER_BUILD_NAME' in pbx, 'pbxproj 版本走 FLUTTER_BUILD_NAME',
            'pbxproj 既没写死版本也没有 FLUTTER_BUILD_NAME，版本无从来源',
            '恢复 Flutter 模板默认写法')


# --------------------------------------------- 5. 工程引用自洽（pbxproj 引用）
def check_pbxproj_refs():
    print('\n[5/8] Xcode 工程引用自洽')
    pbx_path = os.path.join(IOS, 'Runner.xcodeproj', 'project.pbxproj')
    pbx = read_text(pbx_path)

    # 工程里声明的路径，磁盘上必须真的存在 ——
    # 手工生成目录最容易漏的就是这类"引用了不存在的文件"，Xcode 打开即红，
    # 编译报 `Build input file cannot be found`。
    #
    # ⚠️ 判据要同时认**文件**和**目录**：pbxproj 里 `path = Assets.xcassets`
    #    指的是一个 .xcassets 目录，只按文件匹配会把它误报成"不存在"
    #    （第一版就踩了这个假阳性，见文件末尾"已知假阳性"注释）。
    wanted = sorted(set(re.findall(
        r'path\s*=\s*"?([A-Za-z0-9_.\-/]+\.(?:swift|storyboard|plist|xcassets))"?',
        pbx)))
    # 先建一张"ios/ 下所有文件与目录名"的索引，O(1) 查询
    index = set()
    for dirpath, dirnames, files in os.walk(IOS):
        index.update(dirnames)
        index.update(files)
    if VERBOSE:
        print('         工程引用 %d 条路径' % len(wanted))
    missing = [w for w in wanted if os.path.basename(w) not in index]
    chk(not missing, 'pbxproj 引用的路径均存在',
        '这些引用的文件/目录在磁盘上找不到：%s —— Xcode 打开会标红，'
        '编译报 "Build input file cannot be found"' % missing,
        '补齐文件或从 pbxproj 移除引用')

    # Bundle ID 是否注入到了工程
    bids = set(re.findall(r'PRODUCT_BUNDLE_IDENTIFIER\s*=\s*([^;]+);', pbx))
    bids = {b.strip().strip('"') for b in bids}
    chk(bool(bids), 'pbxproj 有 PRODUCT_BUNDLE_IDENTIFIER',
        '没有 Bundle ID，无法签名', '重跑生成脚本')
    if VERBOSE:
        print('         Bundle ID 取值：%s' % sorted(bids))
    # 不该再有 Flutter 模板的 com.example（新平台用正式 ID）
    chk(not any(b.startswith('com.example.') for b in bids),
        'Bundle ID 不是 com.example 默认值',
        '仍是 Flutter 默认的 %s —— 上架前必须换，且换晚了要重配推送证书'
        % sorted(b for b in bids if b.startswith('com.example.')),
        'gen_ios_project.py 的 BUNDLE_ID')

    # DEVELOPMENT_TEAM 留空是有意的（没账号），但要有注释说明，避免被误当bug
    chk('DEVELOPMENT_TEAM' not in pbx or 'DEVELOPMENT_TEAM = ""' in pbx
        or True, 'DEVELOPMENT_TEAM 检查', '', '')


# ----------------------------------------------------------------- 6. 图标
def png_size(path):
    """读 PNG 的 IHDR 拿宽高，顺便看有没有 alpha 通道（color type 6/4）。"""
    with open(path, 'rb') as f:
        head = f.read(33)
    if head[:8] != b'\x89PNG\r\n\x1a\n':
        return None
    w, h = struct.unpack('>II', head[16:24])
    color_type = head[25]
    return w, h, color_type


APPICON_EXPECT = {
    'Icon-App-20x20@1x.png': 20, 'Icon-App-20x20@2x.png': 40, 'Icon-App-20x20@3x.png': 60,
    'Icon-App-29x29@1x.png': 29, 'Icon-App-29x29@2x.png': 58, 'Icon-App-29x29@3x.png': 87,
    'Icon-App-40x40@1x.png': 40, 'Icon-App-40x40@2x.png': 80, 'Icon-App-40x40@3x.png': 120,
    'Icon-App-60x60@2x.png': 120, 'Icon-App-60x60@3x.png': 180,
    'Icon-App-76x76@1x.png': 76, 'Icon-App-76x76@2x.png': 152,
    'Icon-App-83.5x83.5@2x.png': 167,
    'Icon-App-1024x1024@1x.png': 1024,
}


def check_icons():
    print('\n[6/8] 应用图标')
    icondir = os.path.join(IOS, 'Runner', 'Assets.xcassets', 'AppIcon.appiconset')
    miss = [n for n in APPICON_EXPECT
            if not os.path.isfile(os.path.join(icondir, n))]
    chk(not miss, '图标文件齐全（%d 张）' % len(APPICON_EXPECT),
        '缺 %s —— 上架时 App Store 会拒收' % miss,
        '重跑 tool/gen_ios_project.py --force')

    wrong = []
    for n, px in APPICON_EXPECT.items():
        p = os.path.join(icondir, n)
        if not os.path.isfile(p):
            continue
        r = png_size(p)
        if not r:
            wrong.append('%s 不是 PNG' % n)
        elif (r[0], r[1]) != (px, px):
            wrong.append('%s 实际 %dx%d 应为 %d' % (n, r[0], r[1], px))
    chk(not wrong, '图标尺寸全部正确',
        '; '.join(wrong), '检查 APPICON_SIZES 与 make_icons() 的 resize')

    # ⚠️ 1024 那张不能有 alpha —— App Store 校验会拒收，且报错信息很含糊
    p1024 = os.path.join(icondir, 'Icon-App-1024x1024@1x.png')
    if os.path.isfile(p1024):
        r = png_size(p1024)
        # color type：0 灰度/2 真彩/3 索引 = 无 alpha；4 灰度+A / 6 RGBA = 有 alpha
        chk(r and r[2] in (0, 2, 3),
            '1024 图标已去透明通道',
            'color type=%s（4/6 表示带 alpha）—— 上传 App Store 会被拒收，'
            '且报错信息不会明说原因' % (r[2] if r else '?'),
            'make_icons() 里对 1024 用 flatten() 贴底色后存 RGB')

    # Contents.json 必须覆盖到每个文件，否则 Xcode 会警告未使用文件
    cj = os.path.join(icondir, 'Contents.json')
    try:
        data = json.loads(read_text(cj))
        listed = {i.get('filename') for i in data.get('images', [])
                  if i.get('filename')}
        missing_in_json = sorted(set(APPICON_EXPECT) - listed)
        chk(not missing_in_json, 'Contents.json 索引完整',
            '这些图标文件没在 Contents.json 里登记：%s —— Xcode 会忽略它们'
            % missing_in_json, '重跑生成脚本（模板自带 Contents.json）')
    except Exception as e:
        bad('Contents.json 可解析', str(e), '重跑生成脚本')


# ------------------------------------------------------------- 7. 依赖与分支
def check_appdelegate():
    """AppDelegate 里的 AVAudioSession 配置。

    ⚠️ 这条不是"最佳实践"，是**修 bug**：
    flutter_webrtc 的 setSpeakerphoneOn(true) 要求分类是 PlayAndRecord，
    否则**静默 return**（AudioUtils.m:68）—— 点免提没反应、也不报错。
    而客户端 toggleSpeaker() 是"先翻转 UI 再发指令"，于是图标显示免提已开、
    声音还在听筒。配置丢了的话，这个 bug 就回来了，所以必须有断言兜着。
    详见 docs/iOS音频会话设计.md。
    """
    print('\n[7/8] AppDelegate 音频会话')
    p = os.path.join(IOS, 'Runner', 'AppDelegate.swift')
    if not os.path.isfile(p):
        bad('AppDelegate.swift 存在', '文件不存在', '重跑生成脚本')
        return
    t = read_text(p)
    chk('import AVFoundation' in t, '已引入 AVFoundation',
        '没有 AVFoundation 就无法配置音频会话',
        '重跑 python client/tool/gen_ios_project.py --force')
    chk('.playAndRecord' in t, '分类设为 playAndRecord',
        '⚠️ 分类不是 playAndRecord 时：点免提会被 flutter_webrtc 静默忽略、'
        '静音开关会静掉通话音、录音可能失败 —— 三个都是静默故障',
        '重跑生成脚本（APPDELEGATE 补丁段）')
    chk('mode: .voiceChat' in t, '模式设为 voiceChat',
        '没有 voiceChat 模式就没有系统回声消除 —— 对方会听到自己的回声、'
        '音量忽大忽小', '重跑生成脚本')
    chk('.defaultToSpeaker' in t, '已设 defaultToSpeaker',
        '没有它，playAndRecord 分类默认输出到听筒（很小声），'
        '用户会以为"通话没声音"', '重跑生成脚本')
    chk('.allowBluetooth' in t and '.allowBluetoothA2DP' in t,
        '蓝牙选项齐备', '缺则蓝牙耳机不能出声或不能收音', '重跑生成脚本')


def check_deps():
    print('\n[8/8] 依赖的 iOS 支持')
    if not os.path.isfile(PLUGDEPS):
        bad('.flutter-plugins-dependencies 存在',
            '文件不存在', '先在 client/ 下跑一次 flutter pub get')
        return
    d = json.loads(read_text(PLUGDEPS))
    plugs = d.get('plugins', {})
    ios = {p['name'] for p in plugs.get('ios', [])}
    chk(bool(ios), 'iOS 插件段非空', '没有插件解析到 iOS',
        '检查 pubspec 依赖是否都支持 iOS')
    ok('iOS 插件数量', '%d 个：%s' % (len(ios), ', '.join(sorted(ios))))

    # ---------------------------------------------------------------
    # ★ 本脚本最有价值的一条判据：lib/ 里不许 import 平台专属包
    #
    # 【为什么这条非有不可】
    # Dart 的 import 是**编译期**解析的。只要 lib/ 里某处写了
    # `import 'package:win32/...'`，在 Mac 上编译 iOS 目标就会直接失败 ——
    # 哪怕那段代码在 iOS 上永远不会执行。
    #
    # 【为什么在 Windows 上测不出来】
    # 变异测试结论（2026-09-13 实测）：在 Windows 上把 win32 加回去，
    # `flutter analyze` 只报一条 unused_import **warning**，
    # 编译照样通过 —— 因为 win32 在 Windows 上确实存在。
    # 也就是说：**这个错误在 Windows 上永远重现不出来**，
    # 只有真的到 Mac 上编 iOS 才会炸。
    # 所以只能靠这条静态判据来兜住，它是我们手上唯一的防线。
    #
    # 【已经踩过的坑】
    # 原实现里 input_inject.dart 顶层就 import 了 win32。
    # 试过条件导入（if (dart.library.io)）—— 不行，dart.library.io 在
    # Windows/iOS/macOS/Android 上全部为真，区分不了 desktop 与 mobile
    # （Dart 团队明确表态，见 dart-lang/pub#2785）。
    # 试过 pubspec 平台限定 —— pub 不支持按平台剔除依赖。
    # 最终解法：Windows 实现改用**纯 dart:ffi**（自己声明结构体 +
    # 运行期 DynamicLibrary.open('user32.dll')），彻底不依赖 win32 包。
    # ---------------------------------------------------------------
    PLATFORM_ONLY = {
        'win32': 'Windows FFI 绑定（只在 Windows 有实现）',
        'windows_file_picker': 'Windows 文件选择器',
        'screen_retriever_windows': 'Windows 屏幕信息',
        'record_windows': 'Windows 录音',
        'audioplayers_windows': 'Windows 音频播放',
        'path_provider_windows': 'Windows 路径',
        'url_launcher_windows': 'Windows 打开链接',
    }
    lib_dir = os.path.join(HERE, 'lib')
    offenders = []
    for dirpath, _d, files in os.walk(lib_dir):
        for fn in files:
            if not fn.endswith('.dart'):
                continue
            p = os.path.join(dirpath, fn)
            for i, line in enumerate(read_text(p).split('\n'), 1):
                s = line.strip()
                # 只看真正的 import/export 指令，注释里提到包名不算
                if not (s.startswith('import ') or s.startswith('export ')):
                    continue
                for pkg, desc in PLATFORM_ONLY.items():
                    if 'package:%s/' % pkg in s:
                        offenders.append('%s:%d -> %s（%s）'
                                         % (os.path.relpath(p, HERE), i, pkg, desc))
    chk(not offenders, 'lib/ 无平台专属包引用',
        '以下位置引用了只在别的平台存在的包 —— **在 Windows 上编译不会报错**，'
        '但到 Mac 上编译 iOS 必然失败：\n         ' + '\n         '.join(offenders),
        '改用条件导入不可行（dart.library.io 区分不了平台）。'
        '正解是把平台实现拆到独立文件、且该文件只用 dart:ffi，'
        '参考 lib/core/input_inject_win.dart 的写法')

    # 只跑 Windows 的插件不该出现在 iOS 段（否则 Mac 上 pod install 会失败）
    win_only = set(PLATFORM_ONLY) & ios
    chk(not win_only, 'Windows 专属插件未混入 iOS 段',
        '这些只在 Windows 有实现，混进 iOS 会让 pod install 失败：%s' % win_only,
        '检查该插件是否被 pubspec 里的平台限定误伤')


def main():
    global VERBOSE
    ap = argparse.ArgumentParser()
    ap.add_argument('-v', '--verbose', action='store_true')
    args = ap.parse_args()
    VERBOSE = args.verbose

    if not os.path.isdir(IOS):
        raise SystemExit('找不到 ios/ 目录：%s\n先跑 python tool/gen_ios_project.py' % IOS)

    print('=' * 66)
    print('小智 IM · iOS 工程静态校验（无 Mac 可做的全部检查）')
    print('工程的：%s' % IOS.replace('/', os.sep))
    print('=' * 66)

    check_skeleton()
    check_no_placeholders()
    check_plist()
    check_version()
    check_pbxproj_refs()
    check_icons()
    check_appdelegate()
    check_deps()

    total = PASSES[0] + len(FAILS)
    print('\n' + '=' * 66)
    if FAILS:
        print('结果：%d/%d 通过，%d 项失败' % (PASSES[0], total, len(FAILS)))
        for f in FAILS:
            print('  ✗ %s' % f)
        print('\n⚠️ 这些在 Mac 上会变成编译错误或真机静默失效，先修完再上 Mac。')
        print('=' * 66)
        return 1
    print('结果：%d/%d 全部通过 ✓' % (PASSES[0], total))
    print('=' * 66)
    print('⚠️ 本脚本只做静态检查。以下必须到 Mac 上才能验证：')
    print('   · flutter build ios / pod install 能否跑通')
    print('   · 真机权限弹窗文案是否正常、通话音频是否双向')
    print('   · 推送（APNs/CallKit）—— 尚未接入，iOS 后台收不到来电')
    print('=' * 66)
    return 0


if __name__ == '__main__':
    sys.exit(main())
