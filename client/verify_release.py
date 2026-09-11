# -*- coding: utf-8 -*-
"""校验 Flutter release 产物里是否真的包含本轮新代码。

做法：在 AOT 编译后的二进制里按**字节**搜 Dart 标识符。
AOT 会保留类名/方法名/字符串常量，所以这些记号命中就说明新代码确实编进去了
（比"构建成功"这种间接证据可靠得多）。

用法：
    python verify_release.py <文件路径> [特征串...]
不加特征串时用下面的默认集合（对应 v0.5.1 的 Windows 黑屏修复）。
"""
import os
import sys
import zipfile

# v0.5.1「Windows 端视频通话黑屏」修复 + v0.5.2「提示音」的关键记号
#
# 注意：这里只放**函数名 / 字符串常量**。字段名（如 remoteDiag）会被 AOT 直接
# 消除，搜不到是正常的，别拿它当判据 —— 这一点踩过一次，白折腾一轮。
WIN_MARKS = [
    '_attachRemoteTrack',       # 按轨道自建远端流（新增函数）
    '_sweepReceivers',          # 连接后兜底扫描接收器（新增函数）
    '_diag',                    # 诊断记录函数（新增）
    'onFirstFrameRendered',     # 首帧渲染信号（外部 API，UTF-16 命中）
    'createLocalMediaStream',   # 组装远端流用的 API
    'CallService',
    'RTCVideoView',
    # ---- v0.5.2 提示音 ----
    'SoundService',             # 提示音服务
    '_syncTone',                # 通话阶段驱动铃声
    'setTone',                  # 切换来电/呼出铃声
    'CallTone',                 # 铃声枚举（AOT 保留枚举名）
    'assets/sounds/message.wav',
    'assets/sounds/ringtone.wav',
    'assets/sounds/outgoing.wav',
    # ---- v0.6.0 个人信息面板 / 好友验证 / 取消编辑 ----
    'ProfileScreen',            # 个人信息面板
    'FriendAuthSheet',          # 加好友验证弹窗（含模板）
    'NewFriendsScreen',         # 新的朋友（待处理申请）
    'FriendTemplatesScreen',    # 认证消息模板管理
    'updateProfile',            # 更新资料 API
    '/friends/templates',       # 模板接口路径（字符串常量）
    'friend:request',           # 好友申请实时帧
    'user:update',              # 资料变更广播帧
    # ---- v0.6.1 外网通话修复：保活 / 心跳 / TURN 中继 ----
    '/call/ice',                # 服务端下发 ICE 配置的接口路径
    'stun.miwifi.com',          # 新 STUN（旧的内置 stun.qq.com 实测被 RST）
    'stun.chat.bilibili.com',   # 备用 STUN
    'AppLifecycleListener',     # 回到前台主动探活（AOT 保留类名）
    'socket.dart',              # 长连接保活逻辑所在文件
]

# 必须**不再出现**的记号：功能下线 / 资源被替换。
# 只在"确定它不该在产物里"时才加进来 —— 误报会让人白跑一轮构建。
GONE_MARKS = [
    'stun.qq.com',              # v0.6.1：黑龙江电信实测被 RST，已从内置列表剔除
]

# 音频资源条目（必须真的打进包里，否则运行时静默无声）
SOUND_ASSETS = [
    'assets/sounds/message.wav',
    'assets/sounds/ringtone.wav',
    'assets/sounds/outgoing.wav',
]
# Android 侧记号与 Windows 相同。
# 注意别再往里加 `libjingle_peerconnection_so`：那是**原生库的文件名**，
# 只出现在 APK 条目里，不在 libapp.so 的内容中，塞进来必然"未命中"。
# 原生库是否齐三个架构，由 check_apk 单独按条目名判定。
APK_MARKS = list(WIN_MARKS)

# 绿色版必须整体分发，缺一个都起不来
WIN_REQUIRED = [
    'xiaozhi_im_client.exe',
    'flutter_windows.dll',
    'data/app.so',
    'data/icudtl.dat',
    'flutter_webrtc_plugin.dll',
    'libwebrtc.dll',
]


def scan_bytes(data, marks):
    """返回 {记号: 命中次数}。

    Dart AOT 对不同类型的记号保留策略不同：函数名通常留在快照里（栈回溯要用），
    字段名/外部 setter 名经常被优化掉；字符串常量则可能以 UTF-16 存储
    （Dart String 内部是 UTF-16）。所以两种编码都试一遍，命中任一即算命中。
    """
    out = {}
    for m in marks:
        n = data.count(m.encode('utf-8'))
        if n == 0:
            n = data.count(m.encode('utf-16-le'))
        out[m] = n
    return out


def check_gone(data):
    """确认该下线的记号确实没了。

    只验"新东西在不在"是不够的：把 stun.qq.com 从列表里删掉后，
    万一某处还留着硬编码，产物里照样能找到它 —— 而它在本机是被 RST 的，
    会让 ICE 收集白白卡住。所以下线项要单独验"已消失"。
    """
    print('\n-- 应已下线的记号 --')
    bad = []
    for m in GONE_MARKS:
        n = data.count(m.encode('utf-8')) or data.count(m.encode('utf-16-le'))
        if n:
            bad.append(m)
            print('  %-24s 仍存在 x%d ✗' % (m, n))
        else:
            print('  %-24s 已剔除 ✓' % m)
    return not bad


def check_sounds(zf, names, prefix):
    """校验提示音文件是否真的打进包。

    音频漏配 pubspec 的 assets 段时，编译期毫无提示、构建照样成功，
    只有真机收到消息那一刻才发现「没声音」——所以必须显式验条目。
    """
    print('\n-- 提示音资源 (%s) --' % prefix)
    miss = []
    for s in SOUND_ASSETS:
        full = prefix + s
        if full in names:
            print('  %-34s 已打包 %5.1f KB' % (s, zf.getinfo(full).file_size / 1024.0))
        else:
            print('  %-34s 缺失 ✗' % s)
            miss.append(s)
    return not miss


def check_win(zf, marks):
    names = zf.namelist()
    print('条目数: %d' % len(names))
    top = {n.split('/')[0] for n in names}
    nested = [t for t in top if not t.endswith(('.exe', '.dll', '.dat', '.so'))]
    print('顶层目录: %s' % (nested or '无（平铺结构 ✓）'))

    miss = [f for f in WIN_REQUIRED if f not in names]
    print('必需文件: %s' % ('全部齐全 ✓' if not miss else '缺失 %s ✗' % miss))

    target = 'data/app.so'
    if target not in names:
        print('找不到 %s，无法做特征串校验' % target)
        return 1
    data = zf.read(target)
    print('校验对象: %s (%.1f MB)' % (target, len(data) / 1048576.0))

    hits = scan_bytes(data, marks)
    bad = [k for k, v in hits.items() if v == 0]
    for k, v in hits.items():
        print('  %-24s %s' % (k, '命中 x%d' % v if v else '未命中 ✗'))
    gone_ok = check_gone(data)
    snd_ok = check_sounds(zf, names, 'data/flutter_assets/')
    all_ok = not bad and gone_ok and snd_ok
    print('\n结论: %s' % ('新代码已编入产物 ✓' if all_ok else '缺少 %s ✗' % (bad or '提示音/下线项')))
    return 0 if all_ok else 1


def check_apk(zf, marks):
    names = zf.namelist()
    so = [n for n in names if n.endswith('libapp.so')]
    native = [n for n in names if 'libjingle_peerconnection_so' in n]
    print('libapp.so: %d 个 -> %s' % (len(so), so))
    print('WebRTC 原生库: %d 个 -> %s' % (len(native), native))

    if not so:
        print('APK 里没有 libapp.so，异常 ✗')
        return 1
    # 只看 arm64 那份（装机主力），避免重复输出
    pick = [n for n in so if 'arm64' in n] or so
    data = zf.read(pick[0])
    print('校验对象: %s (%.1f MB)' % (pick[0], len(data) / 1048576.0))
    hits = scan_bytes(data, marks)
    bad = [k for k, v in hits.items() if v == 0]
    for k, v in hits.items():
        print('  %-28s %s' % (k, '命中 x%d' % v if v else '未命中 ✗'))
    ok_native = len(native) >= 3
    gone_ok = check_gone(data)
    snd_ok = check_sounds(zf, names, 'assets/flutter_assets/')
    print('\nWebRTC 原生库三架构: %s' % ('齐全 ✓' if ok_native else '不足 ✗'))
    all_ok = not bad and ok_native and gone_ok and snd_ok
    print('结论: %s' % ('新代码已编入产物 ✓' if all_ok else '有问题 ✗'))
    return 0 if all_ok else 1


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    path = sys.argv[1]
    if not os.path.isfile(path):
        print('文件不存在:', path)
        return 2
    marks = sys.argv[2:] or (APK_MARKS if path.lower().endswith('.apk') else WIN_MARKS)

    print('=' * 56)
    print('校验:', path)
    print('大小: %.1f MB' % (os.path.getsize(path) / 1048576.0))
    print('=' * 56)
    with zipfile.ZipFile(path) as zf:
        if path.lower().endswith('.apk'):
            rc = check_apk(zf, marks)
        else:
            rc = check_win(zf, marks)
    print('=' * 56)
    return rc


if __name__ == '__main__':
    sys.exit(main())
