# -*- coding: utf-8 -*-
r"""在**没有 Mac 的 Windows 上**手工补齐 Flutter 工程的 `ios/` 平台目录。

【为什么要自己写这个脚本】
正常做法是 `flutter create --platforms=ios .`，但那条命令**只支持 macOS 主机**
（Flutter 官方限制：iOS 目标只能在 macOS 上构建/生成）。我们手上没有 Mac，
而目标又是"iOS 先做、Mac 后置"，所以改成：**直接拿 Flutter SDK 自带的 iOS 模板
手工渲染出 `ios/` 目录**。

好处：
- 生成的骨架与 `flutter create` 同源（就是同一套模板），不是"另造一套"
- 全部可版本化、可复现：以后 Flutter 升级了，重跑一遍就知道差异

【模板里的 Mustache 变量怎么处理的】
SDK 模板用 Mustache。我们用到的只有：
- 变量：`projectName` / `titleCaseProjectName` / `iosIdentifier` / `pluginProjectName`
- 条件块：`hasIosDevelopmentTeam`（我们没填 team → 整块去掉）、
  `withSwiftPackageManager` + `withPlatformChannelPluginHook`（默认关闭 → 去掉）
处理方式：**只做精确替换与整块删除，不引入 Mustache 引擎** ——
依赖越少，跑在哪儿都一样。渲染完会**校验文件里不残留 `{{`**，漏一个就报错停。

【源文件后缀的三种含义（实测确认）】
- `X.tmpl`        → 渲染后输出为 `X`
- `X.img.tmpl`    → 里面是**二进制图片**，输出为 `X`（别再当文本处理）
- `X.ext.tmpl`    → 同时存在 `X.ext` 与 `X.ext.tmpl` 时，`.tmpl` 版是"图片覆盖版"，
                    优先取它（见 AppIcon/LaunchImage）

用法：
    python tool/gen_ios_project.py            # 生成（已存在则报错，不覆盖）
    python tool/gen_ios_project.py --force    # 覆盖重建
"""
import argparse
import os
import re
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CLIENT = os.path.dirname(HERE)
IOS_DIR = os.path.join(CLIENT, 'ios')

# SDK 模板位置（相对 client/ 往上找 tools/flutter）
FLUTTER_ROOT = os.path.abspath(os.path.join(CLIENT, '..', '..', 'tools', 'flutter'))
TMPL = os.path.join(FLUTTER_ROOT, 'packages', 'flutter_tools', 'templates',
                    'app', 'ios.tmpl')

# ---- 项目参数（以后要改 Bundle ID 就改这里一处）----
PROJECT_NAME = 'xiaozhi_im_client'       # Flutter 工程名（pubspec 的 name）
BUNDLE_ID = 'com.pblpa.xiaozhiIm'        # iOS Bundle ID：新平台用正式 ID
DISPLAY_NAME = '小智 IM'                  # 桌面图标下显示的名字
# ⚠️ DEVELOPMENT_TEAM 故意留空：team ID 要到 Apple 开发者账号里才有。
#    留空时生成的 pbxproj 不含 DEVELOPMENT_TEAM 行（模板里那块会被整块删掉），
#    在 Mac 上打开 Xcode 后选一次团队即可 —— 现在填假的反而会让人误以为配好了。

# 图标源：Windows 的 app_icon.ico 内含 256×256，是手上最高清的一份
ICON_SRC = os.path.join(CLIENT, 'windows', 'runner', 'resources', 'app_icon.ico')

# iOS AppIcon.appiconset 需要的尺寸（文件名 -> 像素）。
# 与模板里的文件名一一对应（模板文件本身是 Flutter 默认占位图，要换成我们自己的）。
# ⚠️ App Store 要求 1024 那张**不能有透明通道**，见下面 flatten()。
APPICON_SIZES = {
    'Icon-App-20x20@1x.png': 20, 'Icon-App-20x20@2x.png': 40, 'Icon-App-20x20@3x.png': 60,
    'Icon-App-29x29@1x.png': 29, 'Icon-App-29x29@2x.png': 58, 'Icon-App-29x29@3x.png': 87,
    'Icon-App-40x40@1x.png': 40, 'Icon-App-40x40@2x.png': 80, 'Icon-App-40x40@3x.png': 120,
    'Icon-App-60x60@2x.png': 120, 'Icon-App-60x60@3x.png': 180,
    'Icon-App-76x76@1x.png': 76, 'Icon-App-76x76@2x.png': 152,
    'Icon-App-83.5x83.5@2x.png': 167,
    'Icon-App-1024x1024@1x.png': 1024,
}

# ---- 内网地址白名单（ATS 明文 HTTP 例外用）----
# ⚠️ ATS 例外**只能按域名/IP 逐个开**，不能写网段通配（iOS 不认 CIDR）。
# 所以这里就把"可能用到的内网 IP"列全。用户换服务器 IP 时改这一行。
# 只开白名单、不开 NSAllowsArbitraryLoads —— 全局放开会在 App Store 审核被
# 要求书面说明理由，而我们确实只需要几个内网地址。
PLAIN_HTTP_HOSTS = ['192.168.31.44']      # 飞牛 NAS（当前生产地址）

# ---- Info.plist 权限声明段 ----
# 这里生成的内容会插进 ios/Runner/Info.plist。
# ⚠️ iOS 缺权限声明**不是报错**，而是「功能静默失效」或「一调到该功能就闪退」，
#    是最容易在真机上踩的坑。每一条的后果都写在下面注释里。
PERMISSIONS_MARK_BEGIN = '<!-- ===== PERMISSIONS BEGIN (gen_ios_project.py) ===== -->'
PERMISSIONS_MARK_END = '<!-- ===== PERMISSIONS END ===== -->'


def permissions_block(indent='\t'):
    """生成权限声明段（含起止标记，便于幂等替换）。"""
    hosts = []
    for h in PLAIN_HTTP_HOSTS:
        hosts.append(
            '{i}\t\t<key>{h}</key>\n'
            '{i}\t\t<dict>\n'
            '{i}\t\t\t<key>NSExceptionAllowsInsecureHTTPLoads</key>\n'
            '{i}\t\t\t<true/>\n'
            '{i}\t\t\t<key>NSIncludesSubdomains</key>\n'
            '{i}\t\t\t<true/>\n'
            '{i}\t\t</dict>'.format(i=indent, h=h))
    host_xml = '\n'.join(hosts)

    return '''{i}{mb}
{i}<!-- ⚠️ 本段由 client/tool/gen_ios_project.py 生成，手改会被下次重建覆盖。
{i}     要增删权限请改脚本里的 PERMISSIONS 段 / PLAIN_HTTP_HOSTS。 -->
{i}<!-- 相机：视频通话 / 拍照发送。缺了会直接闪退（不是禁用，是崩） -->
{i}<key>NSCameraUsageDescription</key>
{i}<string>用于视频通话，以及拍照后发送给对方</string>
{i}<!-- 麦克风：语音通话 / 语音消息 -->
{i}<key>NSMicrophoneUsageDescription</key>
{i}<string>用于语音通话，以及录制语音消息</string>
{i}<!-- 相册读取：发照片 -->
{i}<key>NSPhotoLibraryUsageDescription</key>
{i}<string>用于选择手机里的照片发送给对方</string>
{i}<!-- 相册写入：存收到的图 -->
{i}<key>NSPhotoLibraryAddUsageDescription</key>
{i}<string>用于把收到的图片保存到相册</string>
{i}<!-- ⚠️⚠️ 本地网络：iOS 14 起连局域网设备**必须**声明。
{i}     我们默认连内网 http://192.168.31.44:3602（飞牛 NAS）。
{i}     漏了的典型现象：外网域名能连、内网地址连不上，且**不弹任何提示** ——
{i}     极易被误判成"服务器挂了"，实际是这里少一行。 -->
{i}<key>NSLocalNetworkUsageDescription</key>
{i}<string>用于在局域网内直连你自己的小智 IM 服务器（如家里的飞牛 NAS）</string>
{i}<!-- Bonjour 服务类型。我们连的是纯 IP + 端口，按最小集填，不做过度申报 -->
{i}<key>NSBonjourServices</key>
{i}<array>
{i}\t<string>_http._tcp</string>
{i}</array>
{i}<!-- ⚠️ ATS：iOS 默认禁止明文 HTTP。
{i}     下面**不**全局放开（NSAllowsArbitraryLoads=false），只对指定内网 IP 开例外 ——
{i}     全局放开会在 App Store 审核时被要求书面说明理由，而我们确实只需要这几个地址。 -->
{i}<key>NSAppTransportSecurity</key>
{i}<dict>
{i}\t<key>NSAllowsArbitraryLoads</key>
{i}\t<false/>
{i}\t<key>NSExceptionDomains</key>
{i}\t<dict>
{hosts}
{i}\t</dict>
{i}</dict>
{i}{me}'''.format(i=indent, mb=PERMISSIONS_MARK_BEGIN, me=PERMISSIONS_MARK_END,
                   hosts=host_xml)


def patch_info_plist(plist_path):
    """把权限段写进 Info.plist（幂等：有标记就替换，没有就按锚点插入）。

    为什么要有起止标记：这样重跑脚本不会把权限块叠加成两份，
    也不会因为中间夹了别的 key 而找不到边界。
    """
    if not os.path.isfile(plist_path):
        raise SystemExit('找不到 Info.plist：%s' % plist_path)
    with open(plist_path, 'r', encoding='utf-8') as f:
        text = f.read()

    block = permissions_block()
    if PERMISSIONS_MARK_BEGIN in text:
        # 已有 → 整块换掉（注意吃掉后面那个换行，避免留空行）
        text = re.sub(re.escape(PERMISSIONS_MARK_BEGIN) + r'.*?' +
                      re.escape(PERMISSIONS_MARK_END) + r'\n?',
                      block + '\n', text, flags=re.S)
    else:
        # 首次插入：挂在 LSRequiresIPhoneOS 之后（位置靠前但不影响功能，
        # 排在 CFBundle* 后面方便人肉阅读）
        anchor = '\t<key>LSRequiresIPhoneOS</key>\n\t<true/>\n'
        if anchor not in text:
            raise SystemExit('Info.plist 里找不到插入锚点 LSRequiresIPhoneOS，'
                             '模板可能变了，请人工确认后改这里的 anchor')
        text = text.replace(anchor, anchor + block + '\n', 1)

    with open(plist_path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(text)
    return len(PLAIN_HTTP_HOSTS)


def read_pubspec_version():
    """从 pubspec.yaml 读版本号 → (主版本, build号)。"""
    with open(os.path.join(CLIENT, 'pubspec.yaml'), 'r', encoding='utf-8') as f:
        text = f.read()
    m = re.search(r'^version:\s*([0-9]+(?:\.[0-9]+)*)\+(\d+)', text, re.M)
    if not m:
        raise SystemExit('pubspec.yaml 里读不到 version: X.Y.Z+N')
    return m.group(1), m.group(2)


def patch_pbxproj_version(pbx_path):
    """把 pbxproj 里写死的 MARKETING_VERSION 换成 pubspec 的版本。

    ⚠️ 为什么必须修：Flutter 模板给的 pbxproj 里
         CURRENT_PROJECT_VERSION = "$(FLUTTER_BUILD_NUMBER)";   ← 变量，跟着 pubspec 走
         MARKETING_VERSION      = 1.0;                          ← **写死的 1.0**
       MARKETING_VERSION 才是"用户看到的版本号"（设置-通用-关于本机里显示的那个）。
       不改的话 iOS 端永远显示 1.0，而同一次构建的 Android/Windows 显示 0.9.3 ——
       用户在手机和电脑上看到两个版本号，报障时会说不清。
       本项目有"四处版本号严格一致"的纪律，这是第五处（新平台的）。
    """
    if not os.path.isfile(pbx_path):
        raise SystemExit('找不到 project.pbxproj：%s' % pbx_path)
    ver, build = read_pubspec_version()
    with open(pbx_path, 'r', encoding='utf-8') as f:
        text = f.read()

    old = set(re.findall(r'MARKETING_VERSION\s*=\s*([^;]+);', text))
    text, n = re.subn(r'(MARKETING_VERSION\s*=\s*)[^;]+;', r'\g<1>%s;' % ver, text)
    if n == 0:
        raise SystemExit('pbxproj 里没有 MARKETING_VERSION，模板可能变了；'
                         '请人工确认版本号怎么注入的')
    # CURRENT_PROJECT_VERSION 若被写死也一并纠正（正常是变量，不动）
    text, n2 = re.subn(r'(CURRENT_PROJECT_VERSION\s*=\s*)"[0-9]+";',
                       r'\g<1>"%s";' % build, text)
    with open(pbx_path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(text)
    return ver, sorted(old), n, n2


def check_pbxproj_version(pbx_path):
    """回读确认版本号真的写进去了（不信函数返回值，只信文件）。"""
    ver, _build = read_pubspec_version()
    with open(pbx_path, 'r', encoding='utf-8') as f:
        text = f.read()
    vals = {v.strip().strip('"')
            for v in re.findall(r'MARKETING_VERSION\s*=\s*([^;]+);', text)}
    if vals != {ver}:
        raise SystemExit('MARKETING_VERSION 校正失败，文件里是 %s，期望 %s'
                         % (sorted(vals), ver))
    return len(vals)


# ---- AppDelegate 音频会话补丁 ----
# ⚠️ 为什么代码要用生成器注入，而不是手改 AppDelegate.swift：
#    AppDelegate.swift 是 SDK 模板渲染出来的，`--force` 重建会覆盖手改。
#    和 Info.plist 的权限块同理 —— 脚本必须是唯一事实来源。
APPDELEGATE_MARK = '// ===== AUDIO SESSION (gen_ios_project.py) ====='


def patch_app_delegate(path):
    """在 AppDelegate 启动时配置 AVAudioSession。

    【为什么这段非加不可 —— 不是"最佳实践"，是修 bug】
    flutter_webrtc 的 setSpeakerphoneOn(true) 有这么一段（AudioUtils.m:68）：
        if(enable && config.category != AVAudioSessionCategoryPlayAndRecord) {
          NSLog(@"... defaultToSpeaker is only applicable with category playAndRecord, ignore.");
          return;                     // ← 静默 return，什么也没做
        }
    分类不是 PlayAndRecord 时，**点免提完全不生效，且 Flutter 侧收不到任何错误**。
    而客户端 call_service.dart 的 toggleSpeaker() 是"先翻转 UI 再发指令"，
    于是图标显示"免提已开"、声音却还在听筒 —— 用户只会觉得按钮坏了。

    插件的 ensureAudioSessionWithRecording() 确实会兜底设成 PlayAndRecord，
    但它是在**开采集时**才调；用户"接通后立刻点免提"可能早于那一刻 → 永久失效。
    所以必须在 App 启动时就设好。

    另外几个选项各有具体后果（详见 docs/iOS音频会话设计.md）：
      .voiceChat    → 没有它就没有回声消除，对方会听到自己的回声
      .defaultToSpeaker → 没有它，PlayAndRecord 默认走听筒（小声）
      .allowBluetooth*  → 没有它，蓝牙耳机用不了 / 只能当麦克风
      分类为 PlayAndRecord 还决定：**静音开关不会静掉通话声音**
        （否则用户拨到静音就"电话没声音了"，很难联想到是分类问题）
    """
    if not os.path.isfile(path):
        raise SystemExit('找不到 AppDelegate.swift：%s' % path)
    with open(path, 'r', encoding='utf-8') as f:
        text = f.read()

    if APPDELEGATE_MARK in text:
        # 已打过补丁（按理不该走到这，因为文件是新建的）—— 幂等返回
        return False
    if 'import AVFoundation' not in text:
        text = text.replace('import Flutter\n', 'import AVFoundation\nimport Flutter\n', 1)

    cfg = '''    {mark}
    // 配置音频会话：分类 PlayAndRecord + 模式 VoiceChat。
    // ⚠️ 必须在启动时就设，否则点"免提"会被 flutter_webrtc **静默忽略**
    //    （setSpeakerphoneOn 要求分类为 PlayAndRecord，见 AudioUtils.m:68）。
    //    完整依据与各项选项的后果见 docs/iOS音频会话设计.md。
    do {{
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(
        .playAndRecord,
        mode: .voiceChat,
        options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
      )
    }} catch {{
      NSLog("[xiaozhi] AVAudioSession 配置失败: \\(error)")
    }}

'''.format(mark=APPDELEGATE_MARK)

    anchor = '    return super.application(application, didFinishLaunchingWithOptions: launchOptions)\n'
    if anchor not in text:
        raise SystemExit('AppDelegate.swift 里找不到 didFinishLaunching 的 return 语句，'
                         'SDK 模板可能变了；请人工确认后改这里的 anchor')
    text = text.replace(anchor, cfg + anchor, 1)

    with open(path, 'w', encoding='utf-8', newline='\n') as f:
        f.write(text)
    return True


def check_app_delegate(path):
    """回读确认音频会话配置真的写进去了。"""
    with open(path, 'r', encoding='utf-8') as f:
        t = f.read()
    must = ['import AVFoundation', APPDELEGATE_MARK, '.playAndRecord',
            'mode: .voiceChat', '.defaultToSpeaker']
    missing = [k for k in must if k not in t]
    if missing:
        raise SystemExit('AppDelegate 音频会话写入不完整，缺：%s' % missing)
    return True


def render(text):
    """把 Mustache 模板渲染成最终文本（精确替换 + 整块删除，不引引擎）。

    ⚠️ 三种块都要处理，漏一种就残留：
      `{{#x}}...{{/x}}`  正向块 —— 要删（我们用不到这些可选能力）
      `{{^x}}...{{/x}}`  **反向块** —— 要删（它的语义是"x 不存在时显示"，也属可选能力）
                          ↑ 这个最容易漏。第一次跑就栽在这：
                          `RunnerTests.swift.tmpl` 里的 `{{^withPlatformChannelPluginHook}}`
                          没删掉，被下面的"残留占位符"自检当场抓住。
      `{{/x}}`           块收尾
    """
    for name in ('withSwiftPackageManager', 'withPlatformChannelPluginHook'):
        text = re.sub(r'\{\{[#^/]%s\}\}\n?' % name, '', text)
    # 整块删除：没有 DEVELOPMENT_TEAM
    text = re.sub(r'\{\{#hasIosDevelopmentTeam\}\}.*?\{\{/hasIosDevelopmentTeam\}\}\n?',
                  '', text, flags=re.S)
    # 变量替换
    text = text.replace('{{projectName}}', PROJECT_NAME)
    text = text.replace('{{titleCaseProjectName}}', DISPLAY_NAME)
    text = text.replace('{{iosIdentifier}}', BUNDLE_ID)
    text = text.replace('{{pluginProjectName}}', PROJECT_NAME)
    text = text.replace('{{pluginClass}}', PROJECT_NAME)
    return text


def output_name(rel):
    """模板内相对路径 -> 目标相对路径。三种后缀规则见模块文档。"""
    if rel.endswith('.img.tmpl'):
        return rel[:-len('.img.tmpl')]
    if rel.endswith('.tmpl'):
        return rel[:-len('.tmpl')]
    return rel


def make_icons(assets_root):
    """把 app_icon.ico 切成 iOS 各尺寸图标。

    ⚠️ 1024×1024 那张要去掉透明通道：App Store 校验会拒收带 alpha 的 1024 图标
    （现象是上传时莫名报错，很难联想到透明通道）。做法是贴到蓝色底上再存 RGB。
    """
    from PIL import Image
    if not os.path.isfile(ICON_SRC):
        raise SystemExit('找不到图标源：%s' % ICON_SRC)

    src = Image.open(ICON_SRC)
    # ico 是多尺寸容器，挑最大那张
    sizes = sorted(src.info.get('sizes', []))
    if sizes:
        src.size = sizes[-1]
    src = src.convert('RGBA')

    appicon = os.path.join(assets_root, 'AppIcon.appiconset')
    # 底色取「小智」主色调（与启动图一致）
    BG = (30, 108, 224, 255)
    made = []
    for name, px in sorted(APPICON_SIZES.items()):
        im = src.resize((px, px), Image.LANCZOS)
        if px == 1024:
            flat = Image.new('RGB', (px, px), BG[:3])
            flat.paste(im, (0, 0), im)
            out = os.path.join(appicon, name)
            flat.save(out, 'PNG')
        else:
            out = os.path.join(appicon, name)
            im.save(out, 'PNG')
        made.append(name)

    # 启动图：用主色纯色块（后续可换成带 logo 的图）
    launch = os.path.join(assets_root, 'LaunchImage.imageset')
    for name, px in (('LaunchImage.png', 1), ('LaunchImage@2x.png', 2),
                     ('LaunchImage@3x.png', 3)):
        Image.new('RGB', (px, px), BG[:3]).save(os.path.join(launch, name), 'PNG')
    return made


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--force', action='store_true', help='目标已存在时覆盖重建')
    args = ap.parse_args()

    if not os.path.isdir(TMPL):
        raise SystemExit('找不到 Flutter iOS 模板：%s' % TMPL)
    if os.path.isdir(IOS_DIR):
        if not args.force:
            raise SystemExit('ios/ 已存在，未做任何改动。要重建请加 --force')
        shutil.rmtree(IOS_DIR)

    n_text = n_bin = 0
    for dirpath, _dirnames, filenames in os.walk(TMPL):
        for fn in filenames:
            src = os.path.join(dirpath, fn)
            rel = os.path.relpath(src, TMPL).replace('\\', '/')
            dst_rel = output_name(rel)

            # 同一目标名若已有普通版，且当前是 .img.tmpl → 图片版优先（覆盖）
            dst = os.path.join(IOS_DIR, dst_rel)
            os.makedirs(os.path.dirname(dst), exist_ok=True)

            if fn.endswith('.img.tmpl'):
                shutil.copy2(src, dst)          # 二进制，直接拷
                n_bin += 1
                continue

            with open(src, 'rb') as f:
                raw = f.read()
            try:
                text = raw.decode('utf-8')
            except UnicodeDecodeError:
                shutil.copy2(src, dst)          # 不是文本就原样拷
                n_bin += 1
                continue

            text = render(text)
            # 渲染完不许残留 {{ —— 漏一个变量在 Xcode 里就是玄学错误
            left = re.findall(r'\{\{[^}]*\}\}', text)
            if left:
                raise SystemExit('模板 %s 渲染后仍残留占位符：%s' % (rel, set(left)))
            with open(dst, 'w', encoding='utf-8', newline='\n') as f:
                f.write(text)
            n_text += 1

    # 图标换成我们自己的（模板里是 Flutter 默认图）
    assets = os.path.join(IOS_DIR, 'Runner', 'Assets.xcassets')
    made = make_icons(assets)

    # 权限声明：模板自带的 Info.plist **一条权限都没有**，必须补。
    # 漏了的后果见 permissions_block() 里的注释。
    plist = os.path.join(IOS_DIR, 'Runner', 'Info.plist')
    n_hosts = patch_info_plist(plist)

    # ⚠️ 校验"确实写进去了"：光 return 个数字不算数，得回读文件确认。
    #    （上一轮吃过"脚本说成功了、实际没落盘"的亏）
    with open(plist, 'r', encoding='utf-8') as f:
        check = f.read()
    must = ['NSCameraUsageDescription', 'NSMicrophoneUsageDescription',
            'NSPhotoLibraryUsageDescription', 'NSPhotoLibraryAddUsageDescription',
            'NSLocalNetworkUsageDescription', 'NSBonjourServices',
            'NSAppTransportSecurity']
    missing = [k for k in must if '<key>%s</key>' % k not in check]
    if missing:
        raise SystemExit('Info.plist 权限写入不完整，缺：%s' % missing)
    if check.count(PERMISSIONS_MARK_BEGIN) != 1:
        raise SystemExit('Info.plist 权限块标记数量异常（%d 个），可能有重复段'
                         % check.count(PERMISSIONS_MARK_BEGIN))

    # 版本号：把 pbxproj 里写死的 MARKETING_VERSION 拉到 pubspec 的值。
    # ⚠️ 不修的话 iOS 设置页永远显示 1.0，与 Android/Windows 的 0.9.3 打架。
    pbx = os.path.join(IOS_DIR, 'Runner.xcodeproj', 'project.pbxproj')
    ver, old_ver, n_mv, n_cv = patch_pbxproj_version(pbx)
    n_ok = check_pbxproj_version(pbx)     # 回读校验，不信上面的返回值

    # AppDelegate：注入 AVAudioSession 配置（不注入 = iOS 上免提按钮形同虚设）
    ad = os.path.join(IOS_DIR, 'Runner', 'AppDelegate.swift')
    patch_app_delegate(ad)
    check_app_delegate(ad)                # 同样回读校验

    print('已生成 %s' % IOS_DIR.replace('/', os.sep))
    print('  文本文件 %d 个 / 二进制 %d 个 / 图标重绘 %d 张' % (n_text, n_bin, len(made)))
    print('  权限声明 %d 项已写入 Info.plist（含 %d 个内网明文 HTTP 例外）'
          % (len(must), n_hosts))
    print('  版本号 MARKETING_VERSION: %s -> %s（%d 处，回读校验 %d 组一致）'
          % (','.join(old_ver) or '(无)', ver, n_mv, n_ok))
    if n_cv:
        print('  CURRENT_PROJECT_VERSION 写死值已纠正 %d 处' % n_cv)
    print('  AVAudioSession: PlayAndRecord + VoiceChat 已注入 AppDelegate')
    print('  Bundle ID: %s' % BUNDLE_ID)
    print('  显示名: %s' % DISPLAY_NAME)
    print('  ⚠️ DEVELOPMENT_TEAM 留空 —— 到 Mac 上打开 Xcode 选一次团队即可')
    print('  ⚠️ 推送（APNs/CallKit）尚未接入，iOS 后台收不到来电 —— 见 B 阶段')
    return 0


if __name__ == '__main__':
    sys.exit(main())
