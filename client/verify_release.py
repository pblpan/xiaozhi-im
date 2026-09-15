# -*- coding: utf-8 -*-
"""校验 Flutter release 产物里是否真的包含本轮新代码。

做法：在 AOT 编译后的二进制里按**字节**搜 Dart 标识符。
AOT 会保留类名/方法名/字符串常量，所以这些记号命中就说明新代码确实编进去了
（比"构建成功"这种间接证据可靠得多）。

用法：
    python verify_release.py <文件路径> [特征串...]
不加特征串时用下面的默认集合（对应 v0.5.1 的 Windows 黑屏修复）。

三种产物：
    *.fpk   服务端安装包（tar.gz，拆两层）
    *.apk   Android 安装包
    *.exe   Windows **NSIS 安装包**（v0.9.2 起，取代原先的 zip 绿色版）
            → 用 7-Zip 解出里面的待安装内容，再按原来的判据校验
            → 需要 7-Zip： winget install -e --id 7zip.7zip
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile

# v0.5.1「Windows 端视频通话黑屏」修复 + v0.5.2「提示音」的关键记号
#
# 注意：这里只放**函数名 / 字符串常量**。字段名（如 remoteDiag）会被 AOT 直接
# 消除，搜不到是正常的，别拿它当判据 —— 这一点踩过一次，白折腾一轮。
WIN_MARKS = [
    '_attachRemoteTrack',       # 按轨道自建远端流（新增函数）
    '_sweepReceivers',          # 连接后兜底扫描接收器（新增函数）
    '_diag',                    # 诊断记录函数（新增）
    # ⚠️ 别把 onFirstFrameRendered 放进来。它是 **flutter_webrtc 包自己**的字段，
    #    我们只是给它赋值；该字段名编译在插件侧，**不会出现在我们的 libapp.so 里**，
    #    实测 ascii / UTF-16 两种编码均搜不到 → 拿它当判据必然误报"未命中"。
    #    （曾因此让 v0.7.0 APK 校验假失败一轮，白查一次。）
    #    判据一律用**我们自己的**函数名或字符串常量。
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
    # ---- v0.6.2 好友备注（只自己可见，不改对方昵称）----
    'setFriendRemark',          # 设置备注 API（方法名）
    'noteName',                 # 「我看到的名称」getter：有备注用备注
    'hasRemark',                # 是否设过备注（决定列表副标题展示）
    '/remark',                  # 备注接口路径片段（字符串常量）
    'friends_new.dart',         # 「新的朋友」页（备注入口所在文件）
    # ---- v0.6.3 通话页形态切换修复（被叫端黑屏 / 卡在来电页）----
    # 根因：build() 非响应式读 phase，监听器从不 setState → 接听后不重建。
    # 这两个新增私有方法名是「新代码已进包」的最直接证据
    # （同 _syncTone / _diag 的存活方式，AOT 会保留被 addListener 引用的方法名）。
    '_onSession',               # 新增：会话对象变化也重建
    '_diagPhase',               # 新增：相位跃迁写进诊断面板
    # ---- v0.8.0 客户端配置下发（SPEC-动态配置与模块.md 第一期）----
    # 第一期客户端**只消费免鉴权的 /bootstrap**（防未登录死锁）；
    # /api/client/config 是给第二期「按角色/用户定向下发」预留的服务端骨架，
    # 客户端此刻不调用它 —— 所以 **不要**把 '/api/client/config' 加进来当判据。
    '/api/client/bootstrap',    # 冷启动/轮询拉配置的接口路径（片段常量，能搜到）
    'reportConfigApplied',      # 生效上报（api.dart 新增方法名）
    'RemoteConfig',             # 配置服务单例类名（AOT 保留）
    'hasUserServers',           # 「用户自配地址永不被下发覆盖」的判定函数
    'remote_config.dart',       # 上述逻辑所在文件
    # ⚠️ 下面这些**实测搜不到，禁止当判据**（2026-09-12 探测 APK/WIN 双产物确认）：
    #   kAppVersion / appliedVersion / appliedConfigVersion  → AOT 直接常量折叠消除
    #   '/api/client/config'、'/api/client/report-applied'  → 由 Config.baseUrl 拼接，
    #     只保留 '/api/client/' 之外的片段，完整串不存在
    #   教训与 onFirstFrameRendered 同源：判据必须挑**真能命中**的串，加之前先探测。
    # ---- v0.9.0 动态模块（SPEC-动态配置与模块.md 第二期）----
    # 全部经 2026-09-13 在 APK 双架构 libapp.so 上实测命中（ascii，标注除外）。
    'ModuleRenderer',           # 8 种组件渲染器
    'submitModule',             # 动态表单提交（api.dart 方法名）
    'module_schema.dart',       # 客户端侧的**二次**校验（不信任服务端）
    'module_renderer.dart',     # 渲染器实现
    'module_page.dart',         # 单个模块页面
    # ⚠️ 下面这些**实测搜不到，禁止当判据**（2026-09-13 探测确认）：
    #   '/api/client/modules'、'kVersionForGate'、'fetchModules'、'listVisible'
    #   → 路径由 Config.baseUrl 拼接 / 常量折叠，与 v0.8.0 那批同源问题
    #   中文串（如「动态模块」）只在 UTF-16LE 下能搜到，跨产物不稳，也别用。
    # ---- v0.10.0 远程协助（SPEC-远程协助.md）----
    # 经 2026-09-13 在 Windows 的 data/app.so 与 APK 三架构 libapp.so 上双向实测命中。
    #   ⚠️ absoluteMousePos **不要加**：Win 的 app.so 里有，APK 的 libapp.so 里搜不到
    #      （小函数被内联掉了），加进来会让 APK 校验恒失败。
    'remote_assist.dart',       # WebRTC 屏幕轨 + control DataChannel
    'input_inject.dart',        # 键鼠注入抽象层（Windows 走 Win32 SendInput）
    'remote_models.dart',       # 访问码 / 会话审计的数据模型
    'RemoteAssistWatcher',      # 全局壳：协作请求必须在任何页面之上弹出
    'RemoteHubScreen',          # 入口页（会话列表菜单「远程协助」）
    'parseRemoteInput',         # 控制协议解析（畸形报文不能把 App 搞崩）
    'remoteKeyOf',              # 键盘映射（含 Ctrl/Shift/Alt——漏一格就按不出 Ctrl+C）
    'createInputInjector',      # 按平台挑注入实现（Android 尚不支持时会如实说）
    # ---- v0.9.2 桌面端「关闭=缩到托盘」----
    # 下面 4 条两端（Windows app.so / APK libapp.so）都实测命中；
    # 只活在 Windows 上的另 3 条放在 WIN_ONLY_MARKS。
    # ⚠️ 实测**搜不到**的（本轮踩了一遍，别再往里加）：
    #   attachNavigator / closeAction / setAction → 被 AOT 内联掉
    #   '缩到托盘' 等中文串 → 只有 UTF-16LE 才留，跨产物不稳
    #   教训同源：判据先两端实测，再写进清单。
    'TrayService',              # 托盘 + 关闭行为的服务（类名，AOT 保留）
    'showFromTray',             # 来电时把窗口从托盘拉回来（不拉 = 漏接）
    'actionLabel',              # 菜单「点×时：缩到托盘」的当前值展示
    'xz_close_action',          # 记住的选择存在这个 key 里（能改回去，不做绑架）
    # ---- v0.12.0 工作台 + 考勤打卡 ----
    # 工作台把「内置应用（考勤/申请/组织）」与「自建应用（动态模块）」合成
    # 一个入口 —— 取代了原来的 module_hub.dart（已进 GONE_MARKS，别再加回来）。
    'workbench.dart',           # 工作台页（取代 module_hub.dart）
    'WorkbenchPage',            # 工作台页类名
    'apps.dart',                # 内置应用注册表（id → 页面构造器）
    'builtinAppPage',           # 上面的核心函数：id 不认识就返回 null，不崩
    'clientSatisfiesVersion',   # 客户端侧版本闸门（工作台列表也要卡一次）
    'attendance.dart',          # 考勤打卡页
    'AttendancePage',           # 考勤打卡页类名
    # ---- v0.15.1 考勤记录（管理员专属：今日看板 + 代补卡）----
    # 与 attendance.dart / AttendancePage / attendanceToday 同一类判据（文件名 / 类名 /
    # api 方法名），在同批产物上验证过这类记号能扛住 AOT；新增这三条同样要两端实测。
    'attendance_admin.dart',    # 管理员的考勤记录页
    'AttendanceAdminPage',      # 上面那个页面类名
    'adminAttOverview',         # api.dart：管理端今日看板（与报表同一份判定口径）
    'attendance_records.dart',  # 我的考勤记录（按天 + 当日流水）
    'AttendanceRecordsPage',
    'attendance_request.dart',  # 我的申请（请假/补卡/外出/加班）
    'AttendanceRequestPage',
    'attendanceToday',          # api.dart：今日考勤
    'attendanceClock',          # api.dart：打卡（**不传时间**，时刻由服务端定）
    'clientApps',               # api.dart：工作台应用列表
    # ---- v0.13.0 一天 4 次卡（含午休窗口） ----
    # 下面这几个是**2026-09-14 在 Windows app.so 上逐个实测过**才写进来的：
    #   命中：punchPlan / expectTime / punchLabel / minutesAsHours / restStart
    #   不命中（已排除，别再加）：'in2' 'out2' —— 纯 Dart 标识符被 AOT 内联掉了；
    #                           中文串（'午休下班' '应打' 等）只有 UTF-16LE 才有。
    # 判据挑的是"客户端真的在按服务端下发的计划渲染"的证据：客户端自己判
    # "今天几次卡"是这一期最容易出的错（与报表口径分家），所以这层要卡住。
    'punchPlan',                # attendance.dart / attendance_request.dart：一日打卡计划
    'expectTime',               # 每张卡的应打时刻（按钮上直接写"应打 12:00"）
    'punchLabel',               # "午休下班"这类叫法由服务端下发，客户端不按 type 猜
    'minutesAsHours',           # TimeFmt：在岗时长（480 分钟 → "8 小时"）
    'restStart',                # 午休窗口（有它才谈得上 4 次卡）
    # ⚠️ 下面这些**实测搜不到，禁止当判据**（2026-09-14 在 Windows app.so 上探测确认）：
    #   '/api/client/apps' → 由 Config.baseUrl 拼接，完整串不存在（同 v0.8.0/v0.9.0 那批）
    #   资源路径 'assets/...' 类判据见 SOUND_ASSETS —— 那是单独校验的，别混进来。
]

# 只有 Windows 产物才有的记号。**绝不许混进 APK_MARKS**。
#
# 实测（2026-09-13）：minimizeToTray / tray_manager.dart / window_manager.dart
# 在 APK 的 libapp.so 里一律搜不到 —— 因为 TrayService.supported 在 Android 上恒为
# false，AOT 把「缩到托盘」整条调用链当死代码剔了。这是**预期的好事**（没往移动端
# 塞无用的桌面逻辑），把它当「缺失」去查是浪费时间。反过来 TrayService /
# showFromTray 两端都在，所以留在上面的公共清单里。
WIN_ONLY_MARKS = [
    'minimizeToTray',           # 「关闭 ≠ 退出」的主体动作
    'tray_manager.dart',        # 托盘能力所在文件
    'window_manager.dart',      # 拦截 WM_CLOSE 用的库
]

# 必须**不再出现**的记号：功能下线 / 资源被替换。
# 只在"确定它不该在产物里"时才加进来 —— 误报会让人白跑一轮构建。
GONE_MARKS = [
    'stun.qq.com',              # v0.6.1：黑龙江电信实测被 RST，已从内置列表剔除
    'module_hub.dart',          # v0.12.0：原「应用」页被「工作台」取代，源码已删；
                                #   还在产物里 = 打的是旧代码（构建缓存没清干净）
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

# v0.9.2 起 Windows 走 NSIS 安装程序；下面这些也必须老实躺在安装包里，
# 少一个都起不来（其中托盘图标缺失的表现是：运行时托盘区一片空白）。
WIN_REQUIRED = [
    'xiaozhi_im_client.exe',
    'flutter_windows.dll',
    'data/app.so',
    'data/icudtl.dat',
    'flutter_webrtc_plugin.dll',
    'libwebrtc.dll',
    # 托盘三件套：插件 DLL 缺了功能直接没有，图标缺了只在运行时才看得出来
    'tray_manager_plugin.dll',
    'window_manager_plugin.dll',
    'data/flutter_assets/assets/tray.ico',
]


def find_7z():
    """NSIS 安装包得靠 7-Zip 解，没有就明说怎么装（别让人对着乱猜）。"""
    for cand in (
        os.environ.get('SEVEN_ZIP'),
        os.path.join('C:', os.sep, 'Program Files', '7-Zip', '7z.exe'),
        os.path.join('C:', os.sep, 'Program Files (x86)', '7-Zip', '7z.exe'),
    ):
        if cand and os.path.isfile(cand):
            return cand
    p = shutil.which('7z') or shutil.which('7z.exe')
    if p:
        return p
    raise SystemExit(
        '校验 NSIS 安装包需要 7-Zip：\n'
        '  winget install -e --id 7zip.7zip\n'
        '（或设 SEVEN_ZIP 环境变量指到 7z.exe）'
    )


class SevenZipDir(object):
    """把一个归档解到临时目录，包装成 zipfile.ZipFile 的最小子集（namelist/read/getinfo）。

    这样 check_win 不用改就知道怎么读 —— Windows 产物从 zip 换成 NSIS exe，
    校验逻辑本身不需要动。
    """

    def __init__(self, path, seven_zip=None):
        self._sz = seven_zip or find_7z()
        self._tmp = tempfile.mkdtemp(prefix='xzwin_')
        r = subprocess.run([self._sz, 'x', '-y', '-bso0', '-bsp0',
                            '-o' + self._tmp, path],
                           capture_output=True, text=True, errors='replace')
        if r.returncode != 0:
            shutil.rmtree(self._tmp, ignore_errors=True)
            raise SystemExit('7-Zip 解包失败：%s\n%s' % (r.stdout or '', r.stderr or ''))
        self._files = {}
        for root, _dirs, files in os.walk(self._tmp):
            for f in files:
                full = os.path.join(root, f)
                rel = os.path.relpath(full, self._tmp).replace(os.sep, '/')
                self._files[rel] = full

    def close(self):
        shutil.rmtree(self._tmp, ignore_errors=True)

    def namelist(self):
        return list(self._files.keys())

    def read(self, name):
        with open(self._files[name], 'rb') as f:
            return f.read()

    def getinfo(self, name):
        class Info(object):
            file_size = os.path.getsize(self._files[name])
        return Info()


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


def check_installer_meta(path):
    """确认这真的是个「正规安装程序」，而不是把 zip 改个后缀凑数。

    判据是 NSIS 写进 PE 版本资源的那几个字段（pack_win.py 里用 VIAddVersionKey 填的）。
    少了它们，用户右键「属性」看不到版本号 —— 分发几版之后就再也分不清手上的是哪一版。
    """
    print('\n-- 安装包自身属性 --')
    with open(path, 'rb') as f:
        d = f.read()

    want = ['VS_VERSION_INFO', 'ProductVersion', 'FileDescription', 'LegalCopyright']
    miss = [w for w in want if d.count(w.encode('utf-16-le')) == 0]
    print('  %-24s %s' % ('PE 版本资源', '已写入 ✓' if not miss else '缺失 %s ✗' % miss))

    # 版本号要跟文件名对得上，否则是"改了代码忘了升版本号"或"装的是旧包"
    m = re.search(r'v([0-9]+\.[0-9]+\.[0-9]+)', os.path.basename(path))
    ver_ok = True
    if m:
        want_ver = (m.group(1) + '.0').encode('utf-16-le')
        hit = d.count(want_ver) > 0
        print('  %-24s %s' % ('文件名版本号 %s' % m.group(1),
                              '与包内一致 ✓' if hit else '包内找不到 ✗'))
        ver_ok = hit

    # 安装范围：per-user（asInvoker，免 UAC）还是全局（requireAdministrator）。
    # 期望值跟 pack_win.py 的默认值绑死 —— 有人把 --machine 版当默认发出去时，
    # 这里必须要红，否则「双击就装、不弹 UAC」这条承诺会悄悄失效。
    # NSIS 会把 manifest 明文写进 exe，直接数就够（实测 asInvoker 命中 1 次）。
    as_invoker = d.count(b'asInvoker')
    require_admin = d.count(b'requireAdministrator')
    if as_invoker and not require_admin:
        print('  %-24s %s' % ('安装范围', '用户级 · 免 UAC ✓'))
        level_ok = True
    elif require_admin:
        print('  %-24s %s' % ('安装范围', '全局 · 需 UAC ✗（若确实要发 --machine 版，'
                                          '改 verify_release.py 里这条期望）'))
        level_ok = False
    else:
        print('  %-24s %s' % ('安装范围', '读不到 manifest ✗'))
        level_ok = False

    all_ok = not miss and ver_ok and level_ok
    return all_ok


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

    hits = scan_bytes(data, list(marks) + WIN_ONLY_MARKS)
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


def check_fpk(path):
    """校验服务端 fpk：版本号 + v0.6.1~v0.7.0 关键修复点是否都打进去了。

    fpk 是 tar.gz；app.tgz 里再套一层，所以拆两次。
    """
    import tarfile

    # 文件名 -> 必须出现的特征串
    want = {
        'manifest': ['version', '0.15.0', 'v0.15.0'],
        'src/package.json': ['"version": "0.15.0"'],
        'src/src/routes/call.js': ['iceServers', 'turnConfigured', 'turnSources'],
        # v0.7.0：通话从双人模型改为参与者列表（群通话基础）
        #   participants / activeMembers / join / MAX_PARTICIPANTS 是多方模型的骨架；
        #   `to` 转发是 mesh 定向信令的关键；isOneToOne 必须只读 call.group
        #   （曾用 participants.size 判断，群通话收尾时人被删光会误判成 1v1）。
        # v0.6.1：掉线宽限与来电补推
        #   注意 'call:join' 只出现在 ws.js（路由分发），call.js 里是 'call:joined'
        #   （加入回执）—— 别把两者搞混，否则会误报"缺 call:join"。
        'src/src/call.js': ['OFFLINE_GRACE_MS', 'pendingForUser', 'handleOnline',
                            'participants', 'activeMembers', 'MAX_PARTICIPANTS',
                            'call:peer-joined', 'call:joined', 'call:updated',
                            'isOneToOne', "'call:joined'", 'roomOf'],
        'src/src/ws.js': ['isAlive', "case 'ping'",
                          # v0.7.0：群通话信令路由 + mesh 定向转发
                          "case 'call:join'", 'frame.to',
                          # v0.10.0：远程协助信令（invite/accept/拒绝 + SDP 中继）
                          #   'remote:redeem' 是访问码兑换，"case 'remote:offer'" ~
                          #   'remote:ice' 三个共用一条 relay 分支
                          "case 'remote:invite'", "case 'remote:redeem'",
                          "case 'remote:accept'", "case 'remote:reject'",
                          "case 'remote:offer'", "case 'remote:ice'",
                          'remote.request', 'remote.relay', 'remote.handleOffline'],
        # v0.10.0：远程协助的 REST 路由必须真的挂上去（没挂 = 客户端 404）
        # v0.12.0：考勤的两个前缀同理 —— 管理端那条**必须排在 /api/admin 前面**，
        #   否则会被管理路由先接管、考勤的 admin 接口全部 404（挂载顺序踩过坑）。
        'src/src/index.js': ["'/api/remote'", "require('./routes/remote')",
                             "require('./routes/attendance')",
                             "'/api/attendance'", "'/api/admin/attendance'"],
        # v0.6.3：Cloudflare 托管中继（免端口映射）—— 现场签凭据 + 缓存
        # v0.6.5：新增热加载与凭据探测（管理台向导用）
        'src/src/config.js': ['TURN_URLS', 'iceServers', 'CF_TURN_KEY_ID',
                              'cfTurnServers', 'turnInfo', 'stun.cloudflare.com',
                              'probeTurnCredentials', 'applyTurnCredentials',
                              'cfEnabled'],
        # v0.6.3：好友备注（落在我这一侧，对方看不到）
        # v0.12.0：考勤的 6 张表也在这里（班次/考勤组/组成员/组部门/打卡记录/申请）。
        #   ⚠️ 这些串要并进本条目，**不能单开一条 'src/src/db.js'** ——
        #   同一 dict 字面量里同名键后者覆盖前者，单开会把好友备注与远程协助的
        #   判据悄悄吃掉（下面 app_modules 那条注释里记过同样的坑）。
        'src/src/db.js': ["ensureColumn('friendships', 'remark'",
                          # v0.9.0：动态模块的两张表（定义 + 提交记录）
                          'app_modules', 'module_submissions',
                          # v0.10.0：远程协助的会话审计 + 访问码（只存慢哈希）
                          #   remote_code_attempts 是限流表 —— 没有它就是无限次撞 9 位访问码
                          'remote_sessions', 'remote_access_codes',
                          'remote_code_attempts', 'code_hash', 'idx_remote_codes_user',
                          # v0.12.0：考勤
                          'att_shifts', 'att_groups', 'att_group_members',
                          'att_group_depts', 'att_records', 'att_requests',
                          "ensureColumn('att_shifts', 'early_grace'",
                          # v0.13.0：4 次卡的三处结构变更。
                          #   老库没有这三列 —— 少一列就是启动即崩或在内存里算着玩。
                          "ensureColumn('att_shifts', 'rest_start'",
                          "ensureColumn('att_shifts', 'rest_end'",
                          "ensureColumn('att_records', 'slot'",
                          "ensureColumn('att_requests', 'slot'",
                          # v0.14.0：消息/文件表的查询索引（此前一张都没有）。
                          #   LIKE '%x%' 前导通配符用不上任何索引，所以策略是
                          #   先靠时间/发送者/会话/类型把行数砍下来再做 LIKE ——
                          #   没有这些索引，默认 30 天窗也救不了全表扫描。
                          'idx_messages_created', 'idx_messages_sender',
                          'idx_messages_conv', 'idx_messages_kind',
                          'idx_files_created', 'idx_files_owner', 'idx_files_size',
                          'idx_favorites_message'],
        # v0.10.0：远程协助信令本体（SPEC-远程协助.md）
        #   判据挑的是**安全边界的存在证据**，不是业务流程函数名：
        #     ABORT_WINDOW_MS  → 无人值守"有码也不是立刻能控"，还有 10 秒反悔
        #     MAX_ATTEMPTS     → 兑换限流，掐断暴力撞码
        #     scryptSync       → 访问码存慢哈希（用摘要的话库丢了等于钥匙丢了）
        #     MAX_SESSION_MS   → 单次会话硬上限，防忘断长期挂着
        'src/src/remote.js': ['ABORT_WINDOW_MS', 'MAX_ATTEMPTS', 'MAX_SESSION_MS',
                              'scryptSync', 'remote_code_attempts',
                              'MAX_CODE_SCAN', 'MAX_RELAY_BYTES',
                              'genCode', 'recentAttempts', 'logAttempt',
                              'createCode', 'redeem', 'createCode',
                              # 三条硬边界：1v1 / 只允许发给会话内另一个人 / 掉线即拆
                              'peerOf', 'handleOffline', 'busy',
                              'END_REASON', 'persist', 'markActive'],
        # v0.10.0：远程协助的管理 + 审计接口（也是屏幕上没有的部分）
        'src/src/routes/remote.js': ["'/codes'", "'/codes/:id'", "'/sessions'",
                                     "'/current'", 'listCodes', 'revokeCode',
                                     'history', 'currentOf'],
        'src/src/routes/friends.js': ["'/:friendId/remark'", 'MAX_REMARK'],
        'src/src/chat.js': ['remarkOf',
                            # v0.10.1：告警级别 → 卡片颜色的兼容映射。
                            # 没有它，所有只传 severity 的第三方告警卡片都是默认蓝，
                            # 严重告警和普通通知长得一样（值班时看不出轻重）。
                            'severityToColor', 'SEVERITY_COLORS',
                            # v0.10.1：clip 不再把对象 String 成 "[object Object]"
                            'asText'],
        # v0.10.1：入站推送必须拦住"嵌套报文"这种假成功。
        # 老行为是 String({content:'x'}) → "[object Object]" 且返回 200，
        # 群里出乱码而发送方以为通了。
        'src/src/routes/hooks.js': ['coerceText', 'normalizeBody', 'verifySignature'],
        # v0.6.5：管理台中继配置向导（读状态 / 校验 / 保存 / 移除）
        # v0.8.0：客户端配置中心的管理台接口（读 / 发布 / 回滚 / 同步状态）
        'src/src/routes/admin.js': ["'/turn'", "'/turn/verify'", 'envPath',
                                    'probeTurnCredentials', 'needRecreate',
                                    "'/client-config'", "'/client-config/rollback'",
                                    "'/client-config/applied'", 'clientconfig',
                                    # v0.9.0：动态模块的 CRUD + 提交记录（第二期）
                                    "'/modules'", "'/modules/:id'",
                                    "'/modules/:id/submissions'", 'appmodules',
                                    'capability', 'templates',
                                    # v0.12.0：应用中心总览 + 「为什么看不到」诊断，
                                    # 以及仪表盘/向导要用的考勤计数
                                    "'/apps'", "'/apps/why'", 'appregistry',
                                    'attendanceEnabled', 'attPending',
                                    'attShifts', 'attGroups',
                                    # v0.15.1：诊断要能解释"管理员看不到考勤打卡"，
                                    # 否则管理员只会看到"客户端里没有考勤"然后来问是不是坏了
                                    '管理员专属入口',
                                    # v0.14.0：列表分页 + 按条件批量清理 + 文件巡检。
                                    #   判据挑的是**护栏的存在证据**，不是功能名：
                                    #     purge-preview/purge 成对 → 三步安全模型的第 1、3 步都在
                                    #     MAX_PURGE              → 单次上限（没有它一条宽条件能删空整库）
                                    #     writePurgeBackup       → 删前自动留档（把"不可恢复"变成"能捞回来"）
                                    #     DELETE FROM favorites  → 删消息时清收藏悬空引用
                                    #     pinned_message_id=NULL → 清置顶悬空引用
                                    #     scanOrphans/dbOnly/diskOnly → 库盘不一致的两类都要能查出来
                                    "'/messages/purge-preview'", "'/messages/purge'",
                                    "'/files/purge-preview'", "'/files/purge'",
                                    "'/files/storage'", "'/files/orphans'",
                                    "'/users/options'", "'/conversations/options'",
                                    "'/purge-backups'", 'writePurgeBackup', 'MAX_PURGE',
                                    'scanOrphans', 'dbOnly', 'diskOnly', 'refCount',
                                    'DELETE FROM favorites WHERE message_id',
                                    'pinned_message_id=NULL', 'paging.parseList',
                                    # v0.15.0：仪表盘的时间维度。判据挑的是**口径正确**的证据，
                                    #   不是"有没有这个字段"：
                                    #     msgsToday/usersToday/filesToday → 今日增量三个字段
                                    #     activeUsers7d  → 近 7 天实际发过消息的人数（去重）
                                    #     att.tsOfDay / att.addDays → 时区边界必须复用考勤那套
                                    #       （容器 TZ 常是 UTC，自己用 date('now') 会整体偏 8 小时，
                                    #        且界面上一片正常、只是数字偏小，极难发现）
                                    'msgsToday', 'usersToday', 'filesToday',
                                    'activeUsers7d', 'att.tsOfDay', 'att.addDays'],
        # v0.14.0：全站统一分页约定。这个新文件是"消灭静默截断"的本体 ——
        #   判据要盖住四件事：参数护栏（pageSize 截断 + from>to 报错）、
        #   默认时间窗（不传时间就是最近 30 天）、统一响应形状、LIKE 转义。
        #   少了默认时间窗，关键词搜索会退化成全表扫描；少了转义，输入 % 就匹配全部。
        'src/src/paging.js': ['MAX_PAGE_SIZE', 'DEFAULT_PAGE_SIZE', 'DEFAULT_WINDOW_DAYS',
                              'parseList', 'timeWhere', 'envelope',
                              'escapeLike', 'likeParam', 'allTime', 'sortDir'],
        # v0.12.0：考勤引擎 —— 判据挑的是**口径安全**的证据，不是业务流程函数名。
        #   这一期最难发现的坑是时区：容器 TZ 常是 UTC，用本地时间算打卡
        #   会让所有人的打卡时刻整体偏 8 小时（而且"看起来"是正常的）。
        #   所以第一条判据是 TZ 常量与 Intl.DateTimeFormat —— 有了它才谈得上口径正确。
        #   isValidDay 是另一个真实坑：Date.UTC(2026,12,45) 会**静默归一化**成
        #   2027-02-14，非法日期能写进库，必须真实回验年月日。
        'src/src/attendance.js': ['TZ', 'Intl.DateTimeFormat', 'ATT_TIMEZONE',
                                  'dayOf', 'minutesOfDay', 'tsOfDay', 'weekdayOf',
                                  'defaultShift', 'shiftFor', 'listShifts',
                                  'deptChain', 'deptWithDescendants', 'groupMemberIds',
                                  'clock', 'recordsOn', 'recordsRange',
                                  'judgeDay', 'judgeRange', 'summarize', 'myRange',
                                  'isValidDay', 'createRequest', 'listRequests',
                                  'reviewRequest', 'overview',
                                  # v0.13.0：一天 4 次卡（含午休窗口）
                                  #   punchPlan/windowOf 是唯一口径源：客户端按钮、补卡、判定、
                                  #   报表全部读它，任何一处自己再判"今天几次卡"都会对不上。
                                  #   restWindowOf/workedMinutes/expectedMinutes 是工时口径；
                                  #   slotOf 是**边界校验**：写成 Number(x)===2?2:1 会把 slot=3
                                  #   静默收编成 1，于是补卡补到错误的段上（曾经真踩过）。
                                  'punchPlan', 'windowOf', 'restWindowOf', 'slotOf',
                                  'workedMinutes', 'expectedMinutes',
                                  'punchesPerDay', 'segments', 'restStart', 'restEnd',
                                  "'in2'", "'out2'"],
        # v0.13.0：默认班次的午休窗口校验。
        #   判据挑的是**校验证据**而不是字段名：两个都填/两个都空/只填一个的
        #   三分支必须都在，且错误文案真的提到了"午休"—— 只判 restStart 存在的话，
        #   把校验删掉照样通过，而"只填一个"会静默算错在岗时长。
        'src/src/settings.js': ['attDefaultShift', 'cleanShift',
                                'restStart', 'restEnd', '午休开始', '午休结束',
                                '跨天班（夜班）不支持午休窗口'],
        # 应用中心注册表：内置应用清单 + 按业务状态过滤可见性
        'src/src/apps.js': ['BUILTIN_APPS', 'listFor', 'catalog', 'GROUPS',
                            "'attendance'", "'my_requests'", "'work_org'",
                            # v0.15.1：管理员的考勤入口（看板 + 代补卡）与它的判据。
                            # 只认业务状态不认开关，所以 adminOnly 必须真在过滤逻辑里。
                            "'att_admin'", 'adminOnly'],
        # 考勤 REST（用户端 + 管理端两个 Router）
        'src/src/routes/attendance.js': ["'/today'", "'/clock'", "'/my'",
                                         "'/records'", "'/requests'",
                                         "'/requests/:id/cancel'",
                                         "'/requests/:id/review'",
                                         "'/shifts'", "'/shifts/:id'",
                                         "'/groups'", "'/groups/:id'",
                                         'admin.get', 'admin.put', 'admin.post',
                                         'admin.delete', 'express.Router()',
                                         # v0.13.0：把"该打几次卡"与"这是第几次卡"下发出去。
                                         #   punchView/shiftView 是给客户端与报表的展示形态，
                                         #   punchLabel 让同一个 type=out 在 4 次卡里显示成
                                         #   "午休下班"、在 2 次卡里显示成"下班"（客户端按 type
                                         #   猜只会猜错）。
                                         'punchPlan', 'punchView', 'shiftView',
                                         'punchLabel', 'expectedWorkMinutes'],
        # v0.8.0：客户端配置下发（SPEC-动态配置与模块.md 第一期）
        #   clientconfig.js 是配置中心本体：白名单校验 / 只增不改的版本快照 /
        #   回滚=用旧内容发新版。routes/client.js 是下发出去的口子：
        #   bootstrap 免鉴权（未登录也要能拿地址，否则死锁），report-applied 上报。
        'src/src/clientconfig.js': ['DEFAULT_CONFIG', 'client_configs',
                                    'validate', 'publish', 'rollback',
                                    'reportApplied', 'appliedStatus',
                                    'minClientVersion', 'announcements'],
        'src/src/routes/client.js': ['/bootstrap', '/config', '/report-applied',
                                     'clientconfig',
                                     # v0.9.0：动态模块访问与提交（第二期）
                                     "'/modules/:id'", "'/modules/:id/submit'",
                                     'appmodules', 'listVisible',
                                     # v0.12.0：工作台把内置应用与自建应用合并下发
                                     'appregistry', 'req.query.clientVersion',
                                     # v0.15.1：管理员的「考勤记录」带待审批角标
                                     #   （角标只查 COUNT，不跑全员判定 —— 冷启动别为
                                     #    一张卡片付 judgeRange 的代价）
                                     "'att_admin'"],
        # v0.9.0：动态模块中心（SPEC-动态配置与模块.md 第二期）
        #   这一期的全部风险都在"服务端下发的 schema 会不会把客户端搞崩 / 变成 SSRF 跳板"，
        #   所以判据挑的是**三道闸门**的存在证据，而不是 CRUD 函数名：
        #     COMPONENTS  → 封闭组件集（未知组件名一律拒绝）
        #     ACTIONS / '/api/hooks/' → 动作白名单 + 只允许这个前缀（防任意 URL 转发）
        #     COLORS      → 颜色只允许语义枚举（防写死色值把深色主题搞成黑底黑字）
        #     sanitizeSubmission → 提交按服务端 schema 清洗，不信任客户端
        'src/src/appmodules.js': ['COMPONENTS', 'ACTIONS', 'COLORS', 'FIELD_TYPES',
                                  'NAV_PAGES', 'TEMPLATES', 'MAX_DEPTH', 'MAX_COMPONENTS',
                                  "'/api/hooks/'", 'validateComponent', 'validateAction',
                                  'listVisible', 'versionGte', 'collectFormFields',
                                  'sanitizeSubmission', 'recordSubmission'],
        # v0.9.0：动态模块的表（app_modules 定义 + module_submissions 提交记录）
        # ⚠️ 这两个串要并进上面那条 db.js 的判据里 —— dict 字面量里同名键后者覆盖前者，
        #    单开一条会把「好友备注」的判据悄悄吃掉。

        'docker/coturn/entrypoint.sh': ['detect_lan_ip', 'EXTERNAL_IP_VALUE'],
        'docker/coturn/turnserver.conf': ['__EXTERNAL_IP__', '__MIN_PORT__'],
        'docker/docker-compose.yaml': ['coturn', 'TURN_INTERNAL_IP', 'TURN_URLS',
                                       'CF_TURN_KEY_ID'],
        'cmd/_xiaozhi_common.sh': ['transport=tcp', 'transport=udp',
                                   'CF_TURN_KEY_ID', 'OLD_CF_ID',
                                   # v0.6.4：必须强制重建，否则 callback 重写的
                                   # .env 进不了已经存在的容器（踩过两次）
                                   '--force-recreate'],
    }
    # 必须彻底消失的（v0.6.1 起）。
    # 注意用带 scheme 的完整写法：config.js 里有一条注释提到过
    # stun.qq.com（解释为什么把它换掉），那属于正常注释，不要误报。
    gone = ['stun:stun.qq.com']

    blob = {}
    with tarfile.open(path, 'r:gz') as t:
        for m in t.getmembers():
            if m.isfile():
                blob[m.name.lstrip('./')] = t.extractfile(m).read()
        inner = [n for n in blob if n.endswith('app.tgz')]
        if inner:
            import io
            with tarfile.open(mode='r:gz', fileobj=io.BytesIO(blob[inner[0]])) as t2:
                for m in t2.getmembers():
                    if m.isfile():
                        blob[m.name.lstrip('./')] = t2.extractfile(m).read()

    print('解包条目: %d' % len(blob))
    all_ok = True
    for name, marks in want.items():
        data = blob.get(name)
        if data is None:
            print('%-30s 缺失 ✗' % name)
            all_ok = False
            continue
        miss = [s for s in marks if s.encode('utf-8') not in data]
        if miss:
            print('%-30s 缺 %s ✗' % (name, miss))
            all_ok = False
        else:
            print('%-30s 全部命中 ✓' % name)

    # 管理台是 vite 构建产物，文件名带内容哈希，写不死；
    # 按目录扫一遍，确认新的「系统帮助」页真的打进包里了。
    admin_js = [n for n, d in blob.items()
                if n.startswith('src/public/assets/') and n.endswith('.js')]
    help_hit = [n for n in admin_js
                if '系统帮助'.encode('utf-8') in blob[n]
                and 'Cloudflare TURN'.encode('utf-8') in blob[n]]
    print('%-30s %s' % ('src/public/assets(系统帮助页)',
                        '命中 ✓' if help_hit else '缺失 ✗'))
    all_ok = all_ok and bool(help_hit)

    # v0.6.5：帮助里必须有「从零申请」的完整步骤（用户明确要求写进去），
    # 且要提醒「不需要信用卡」—— 这是被问过的高频误解，少一句就得重新解释。
    guide_hit = [n for n in admin_js
                 if '不需要信用卡'.encode('utf-8') in blob[n]
                 and 'TURN 服务器'.encode('utf-8') in blob[n]
                 and 'realtime/turn'.encode('utf-8') in blob[n]]
    print('%-30s %s' % ('src/public/assets(申请步骤)',
                        '命中 ✓' if guide_hit else '缺失 ✗'))
    all_ok = all_ok and bool(guide_hit)

    # v0.6.5：管理台「系统设置」里要出现中继配置向导的 UI
    wizard_hit = [n for n in admin_js
                  if '音视频中继配置'.encode('utf-8') in blob[n]
                  and 'Turn 令牌 ID'.encode('utf-8') in blob[n]]
    print('%-30s %s' % ('src/public/assets(中继向导)',
                        '命中 ✓' if wizard_hit else '缺失 ✗'))
    all_ok = all_ok and bool(wizard_hit)

    # v0.15.1：帮助与「应用中心」说明必须讲清**两类人看到的工作台不一样**。
    # 这一条是有来历的：曾出现"管理员在手机上只看到组织通讯录、以为打卡功能坏了"
    # 的反馈 —— 真实原因是他账号是管理员（不参与考勤）、他看到的是「考勤记录」。
    # 所以说明里必须同时出现"管理员专属"与"代员工补卡"，否则下次同样要重新解释一遍。
    role_hit = [n for n in admin_js
                if '管理员专属'.encode('utf-8') in blob[n]
                and '代员工补卡'.encode('utf-8') in blob[n]
                and '考勤记录'.encode('utf-8') in blob[n]]
    print('%-30s %s' % ('src/public/assets(两个角色说明)',
                        '命中 ✓' if role_hit else '缺失 ✗'))
    all_ok = all_ok and bool(role_hit)

    # 向导绝不能把明文密钥渲染进静态产物。
    # ⚠️ 这里**绝对不要**写真实凭据去做比对 —— 本仓库是公开的，
    #    一旦把 KEY_ID / API Token 写进源码，等于把它们直接公开出去
    #    （曾经真的这么干过：用真值当"不该出现的串"，等于自曝密钥）。
    #    改为按**形态**检测：只要产物里出现「CF_TURN_ 键名 + 16 位以上 hex 值」
    #    就报警。不依赖任何真实值，目的完全一样。
    CRED_RE = re.compile(
        rb'CF_TURN_(?:KEY_ID|API_TOKEN)\s*[:=\'"]+\s*[0-9a-fA-F]{16,}')
    leak = [n for n in admin_js if CRED_RE.search(blob[n])]
    print('%-30s %s' % ('src/public/assets(无明文密钥)',
                        '干净 ✓' if not leak else '泄漏 ✗ %s' % leak))
    all_ok = all_ok and not leak

    # v0.6.4：说明文案里去掉了「仿 Tailchat 界面」的表述，产物里不该再有该词。
    tail = [n for n in admin_js if b'Tailchat' in blob[n]]
    print('%-30s %s' % ('src/public/assets(去 Tailchat)',
                        '已清除 ✓' if not tail else '仍存在 ✗ %s' % tail))
    all_ok = all_ok and not tail

    # v0.7.0：群通话不能回退成双人模型。
    # 具体的失败形态：isOneToOne 又拿 participants.size 做判断 —— 群通话收尾时
    # 人已被删光，size=0 会被误判成 1v1，通话记录丢掉 group 标记、
    # end() 走错分支。这条断言直接扫源码形态，比跑测试更早拦住。
    call_src = blob.get('src/src/call.js', b'')
    bad_1v1 = b'participants.size <= 2'
    print('%-30s %s' % ('src/src/call.js(非 size 判 1v1)',
                        '干净 ✓' if bad_1v1 not in call_src else '回退 ✗ 又用 participants.size 判 1v1'))
    all_ok = all_ok and bad_1v1 not in call_src

    # v0.8.0：管理台「客户端配置」页必须真打进静态产物。
    # 判据用页面里独有的中文 UI 串（编辑区标题 + 发布按钮语义），
    # 不用文件名 —— vite 产物名带内容哈希，写不死。
    #   判据串要跟 App.vue 里**一模一样**：页面标题是「客户端配置」，
    #   按钮实际写的是「发布…」/「确认发布」（不是"发布新版本"）—— 差一个字就误报。
    cfg_hit = [n for n in admin_js
               if '客户端配置'.encode('utf-8') in blob[n]
               and '同步状态'.encode('utf-8') in blob[n]
               and '回滚'.encode('utf-8') in blob[n]]
    print('%-30s %s' % ('src/public/assets(客户端配置页)',
                        '命中 ✓' if cfg_hit else '缺失 ✗'))
    all_ok = all_ok and bool(cfg_hit)

    # v0.9.0：管理台「动态模块」页必须真打进静态产物。
    # 判据用页面独有的中文 UI 串（左栏标题 + 模板库分隔 + 可见范围字段名），
    # 与 App.vue 完全一致 —— 改文案就要同步改这里，反过来也提醒"页面还在"。
    mm_hit = [n for n in admin_js
              if '模块清单'.encode('utf-8') in blob[n]
              and '模板库'.encode('utf-8') in blob[n]
              and '可见范围'.encode('utf-8') in blob[n]]
    print('%-30s %s' % ('src/public/assets(动态模块页)',
                        '命中 ✓' if mm_hit else '缺失 ✗'))
    all_ok = all_ok and bool(mm_hit)

    # v0.12.0：管理台「考勤管理」页必须真打进静态产物。
    # 判据挑**只出现在页面标记里**的串（帮助文档里没有），否则"帮助写到了但页面没打进去"
    # 也会假通过：『所选日期是休息日』只在打卡看板的标记里，『班次名称』只在班次表里。
    # 再配三个标签页名。改文案就要同步改这里，反过来也提醒"页面还在"。
    att_hit = [n for n in admin_js
               if '所选日期是休息日'.encode('utf-8') in blob[n]
               and '班次名称'.encode('utf-8') in blob[n]
               and '统计报表'.encode('utf-8') in blob[n]
               and '班次与考勤组'.encode('utf-8') in blob[n]
               and '申请审批'.encode('utf-8') in blob[n]]
    print('%-30s %s' % ('src/public/assets(考勤管理页)',
                        '命中 ✓' if att_hit else '缺失 ✗'))
    all_ok = all_ok and bool(att_hit)

    # v0.13.0：管理台必须真把"一天 4 次卡"的界面打进去。
    #   判据挑**只出现在页面标记里**的串（帮助文档里没有），否则"帮助写到了但
    #   页面没打进去"也会假通过 —— 这一条与上一段同样踩过坑。
    #   清空（改回 2 次卡）= 考勤设置的午休清空按钮
    #   补哪张卡         = 补卡弹窗的卡选择项（带 slot，4 次卡的关键）
    #   今日打卡         = 看板列头（逐张卡渲染取代原"上班/下班"两列）
    #   在岗/应出勤      = 报表列头（工时口径）
    rest_hit = [n for n in admin_js
                if '清空（改回 2 次卡）'.encode('utf-8') in blob[n]
                and '补哪张卡'.encode('utf-8') in blob[n]
                and '今日打卡'.encode('utf-8') in blob[n]
                and '在岗/应出勤'.encode('utf-8') in blob[n]]
    print('%-30s %s' % ('src/public/assets(一天4次卡 UI)',
                        '命中 ✓' if rest_hit else '缺失 ✗'))
    all_ok = all_ok and bool(rest_hit)

    # v0.14.0：管理台必须真把"分页 + 筛选 + 批量清理 + 文件巡检"的界面打进去。
    #   判据全部挑**只出现在新页面代码里**的串（内置帮助文档里一个都没有，
    #   已逐个核对过）—— 否则"帮助写了但页面没打进去"也会假通过。
    #   库盘不一致 / 存储占用分析 = 文件页统计与分析区块
    #   孤儿巡检                   = 文件页第二个标签页
    #   手工输入 / 清理条件        = 批量清理确认弹窗（三步安全模型的第 2 步）
    list_hit = [n for n in admin_js
                if '库盘不一致'.encode('utf-8') in blob[n]
                and '存储占用分析'.encode('utf-8') in blob[n]
                and '孤儿巡检'.encode('utf-8') in blob[n]
                and '手工输入'.encode('utf-8') in blob[n]
                and '清理条件'.encode('utf-8') in blob[n]]
    print('%-30s %s' % ('src/public/assets(分页/批量清理 UI)',
                        '命中 ✓' if list_hit else '缺失 ✗'))
    all_ok = all_ok and bool(list_hit)

    # v0.15.0：管理台必须真把"分组指标卡 + 异常提醒条"的界面打进去。
    #   判据已按纪律在**已构建产物**里逐个实测命中过（grep index-*.js 各 1 次），
    #   不是"看着代码里有就写上"。
    #   近 7 天活跃       = 唯一能说明"系统真在被使用"的指标卡（原来只有用户总数）
    #   条事件投递失败    = 异常提醒条的标题模板（拼出来的，正文里没有）
    #   去看投递日志      = 提醒条上的跳转按钮
    #   组织与考勤        = 仪表盘分组标题（工作模式才出现的那一组）
    #   mgroup-ic         = 分组图标色块的 class（不引图标库的做法）
    #   mtile-warn        = "真异常才标红"的样式类（待审批那种日常数字不该标红）
    dash_hit = [n for n in admin_js
                if '近 7 天活跃'.encode('utf-8') in blob[n]
                and '条事件投递失败'.encode('utf-8') in blob[n]
                and '去看投递日志'.encode('utf-8') in blob[n]
                and '组织与考勤'.encode('utf-8') in blob[n]
                and b'mgroup-ic' in blob[n]
                and b'mtile-warn' in blob[n]]
    print('%-30s %s' % ('src/public/assets(仪表盘分组卡)',
                        '命中 ✓' if dash_hit else '缺失 ✗'))
    all_ok = all_ok and bool(dash_hit)

    # v0.8.0：bootstrap 免鉴权是硬要求，但绝不能因此把用户定向内容漏出去。
    # 判据：bootstrap 分支里不得出现 verifyToken（只有 /config 与上报才鉴权）。
    #   注意别用"文件里出现 verifyToken"来判 —— uidOf() 定义在文件上方，
    #   那样必然误报。只截取 '/bootstrap' 到下一个 router.get 之间的处理函数体。
    cjs = blob.get('src/src/routes/client.js', b'')
    boot_seg = b''
    if b"'/bootstrap'" in cjs:
        boot_seg = cjs.split(b"'/bootstrap'", 1)[1].split(b'router.get', 1)[0]
    boot_ok = bool(boot_seg) and b'uidOf' not in boot_seg and b'verifyToken' not in boot_seg
    print('%-30s %s' % ('routes/client.js(bootstrap 免鉴权)',
                        '正确 ✓' if boot_ok else '异常 ✗'))
    all_ok = all_ok and boot_ok

    # v0.9.0：bootstrap 还必须**只下发"所有人可见"的模块**。
    # 免鉴权接口一旦带上"仅管理员可见"的模块列表，等于公开了权限结构；
    # 判据是该分支里出现了 listVisible + visibleTo 过滤（证明真的筛过），
    # 而不是直接把 appmodules.list() 全量吐出去。
    boot_filter_ok = (b'listVisible' in boot_seg and b'visibleTo' in boot_seg
                      and b'list()' not in boot_seg)
    print('%-30s %s' % ('routes/client.js(bootstrap 过滤定向模块)',
                        '正确 ✓' if boot_filter_ok else '异常 ✗'))
    all_ok = all_ok and boot_filter_ok

    # v0.12.0：/apps 必须把客户端的 ?clientVersion= 交给 listVisible 做过滤。
    #   漏传的后果**不是报错**，而是"凡设了「最低客户端版本」的自建应用整个消失"
    #   （cv 为空串 → versionGte 一律 false），现象是"管理台明明发布了、
    #   客户端工作台里就是没有"，很难查 —— 曾经真实发生过一轮。
    #   这里按**形态**判：/apps 处理函数体里必须同时出现 clientVersion 与 listVisible。
    apps_seg = b''
    if b"'/apps'" in cjs:
        apps_seg = cjs.split(b"'/apps'", 1)[1].split(b'router.', 1)[0]
    apps_cv_ok = b'clientVersion' in apps_seg and b'listVisible' in apps_seg
    print('%-30s %s' % ('routes/client.js(/apps 传 clientVersion)',
                        '正确 ✓' if apps_cv_ok else '异常 ✗ 漏传会让自建应用整个消失'))
    all_ok = all_ok and apps_cv_ok

    hits = []
    for name, data in blob.items():
        for g in gone:
            if g.encode('utf-8') in data and name.endswith(('.js', '.dart')):
                hits.append('%s @ %s' % (g, name))
    print('\n应剔除项 %s: %s' % (gone, '已清除 ✓' if not hits else '仍存在 ✗ %s' % hits))
    all_ok = all_ok and not hits

    print('\n结论: %s' % ('服务端改动已全部打入 fpk ✓' if all_ok else '有问题 ✗'))
    return 0 if all_ok else 1


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    path = sys.argv[1]
    if not os.path.isfile(path):
        print('文件不存在:', path)
        return 2

    print('=' * 56)
    print('校验:', path)
    print('大小: %.1f MB' % (os.path.getsize(path) / 1048576.0))
    print('=' * 56)

    if path.lower().endswith('.fpk'):
        return check_fpk(path)

    marks = sys.argv[2:] or (APK_MARKS if path.lower().endswith('.apk') else WIN_MARKS)
    if path.lower().endswith('.exe'):
        # NSIS 安装程序：内容压缩在里面，先解出来再按同一套判据校验。
        # 7z 的项名不带盘符，Windows 这边源码结构和以前 zip 版一致，可直接复用。
        sz = SevenZipDir(path)
        try:
            rc = check_win(sz, marks)
            meta_ok = check_installer_meta(path)
        finally:
            sz.close()
        print('=' * 56)
        return rc or (0 if meta_ok else 1)

    with zipfile.ZipFile(path) as zf:
        if path.lower().endswith('.apk'):
            rc = check_apk(zf, marks)
        else:
            rc = check_win(zf, marks)
    print('=' * 56)
    return rc


if __name__ == '__main__':
    sys.exit(main())
