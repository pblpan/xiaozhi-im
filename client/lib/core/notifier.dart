import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models.dart';
import '../socket.dart';
import 'badges.dart';

/// 新消息通知 + 桌面图标角标（仅 Android 有原生实现，桌面端整套跳过）。
///
/// 龙哥 2026-10-14 报的两个现象都由这个类补上：
///   ① 「App 在后台没有消息提示」——  socket 其实一直收得到（SoundService
///      照响），但通知栏什么都没有、用户不点开 App 就不知道来消息了；
///   ② 「软件图标上没有小红点数量」——  launcher 角标没人写。
///
/// 为什么不用 FCM/厂商推送：那需要一台公网推送服务器 + Firebase 项目，
/// 而本项目刻意不依赖 Google 服务（geolocator 都走 forceLocationManager）。
/// 这里的做法是**应用内 socket 还活着时**由原生直接发本地通知 ——
/// App 刚切后台（最常见的情形）完全覆盖；进程被系统杀掉则收不到
/// （已知限制，要覆盖得上 FCM，那是另一个工程）。
///
/// 通知的响/静音分两个通道在原生侧解决（见 MessageNotifier.kt）：
/// 后台到达震+弹条、前台到达只更新角标，不会双响。
class MessageNotifier {
  static final MessageNotifier instance = MessageNotifier._();
  MessageNotifier._();

  /// 与 MainActivity.kt 里 MessageNotifier.CHANNEL 必须逐字一致
  /// （写错 = 通知静默失效，且不报错）
  static const MethodChannel _ch = MethodChannel('xiaozhi/notify');

  static const _kAskedPerm = 'xz_notify_perm_asked';

  /// 当前登录用户 id（由会话页登录成功后写入），用来过滤「自己发的不通知」
  int myId = 0;

  /// App 是否在前台（main.dart 的生命周期驱动）
  bool _foreground = true;
  bool get isForeground => _foreground;

  /// 用户此刻正盯着的会话 id（聊天页打开时写入）—— 看这个会话时不再弹通知
  int? _openConv;

  /// 通知权限是否已拿到（false = 还没问过或被拒）
  final ValueNotifier<bool> granted = ValueNotifier(false);

  /// 权限被拒过一次：给 UI 提示「去系统设置打开」用（只提示一次）
  final ValueNotifier<bool> denied = ValueNotifier(false);

  /// 通知栏点击 → 要打开的会话 id（null = 没有待处理的点击）。
  /// 会话页监听它并消费；冷启动时点击可能比首页先到，所以存 pending。
  final ValueNotifier<int?> tap = ValueNotifier(null);

  StreamSubscription? _sub;

  // ---------------- 名字/类型缓存 ----------------
  // 通知标题要「对方名字 / 群名」，正文群聊要带发送者名字。这两个信息
  // 分别只有会话列表页和聊天页拿得到，所以由它们往这里喂（纯缓存，
  // 喂不到就退化成"新消息"，不影响功能成立）。
  final Map<int, String> _convTitles = {};
  final Map<int, String> _convTypes = {};
  final Set<int> _mutedConvs = {};
  final Map<int, String> _userNames = {};

  /// 当前角标数（通知里 setNumber 用）。自己递增 + 服务端真值纠正。
  int _badgeNumber = 0;

  bool _attached = false;

  // ---------------- 装配 ----------------

  /// 订阅全局消息流 + 镜像未读角标。main() 里调一次。
  void attach() {
    if (_attached) return;
    _attached = true;
    _sub = SocketService().stream.listen(_onFrame);
    // 原生 → Dart 的回调：通知栏点击（App 活着时）、授权结果异步回来
    _ch.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onNotificationTap':
          onNativeTap(call.arguments);
          break;
        case 'permissionResult':
          onPermissionResult(call.arguments == true);
          break;
      }
    });
    // 未读清零（用户在手机上读完了 / 别的设备读完了）→ 撤掉通知栏残留。
    // 非零变化不管：下一条消息到达时会带上最新数字自愈。
    Badges.instance.unread.addListener(_onUnreadChanged);
  }

  /// 登录成功后调用：申请通知权限 + 取冷启动时可能已经到达的通知点击。
  ///
  /// 刻意放在登录后而不是 main()：没登录就问通知权限，用户会莫名其妙。
  /// 登出后 [detach] 掉的那套监听也在这里重新挂上（幂等）。
  Future<void> arm() async {
    attach(); // 登出→再登录的路径：main() 里那次已被 reset() 摘掉
    if (!Platform.isAndroid) return;
    // 冷启动点击：原生在 configureFlutterEngine 时就把 intent 存好了，
    // 等 Dart 接上通道（就是此刻）再取走。
    try {
      final conv = await _ch.invokeMethod<int>('getInitialNotification');
      if (conv != null && conv > 0) _onTap(conv);
    } catch (_) {
      // 通道不通（极端情况）不该拦着登录流程
    }
    try {
      final p = await SharedPreferences.getInstance();
      if (p.getBool(_kAskedPerm) == true) {
        // 问过了：直接读当前状态，不再弹第二次窗（Android 连拒两次后
        // 本来也不再弹，但有些国产 ROM 会反复弹，骚扰用户）
        granted.value = await _hasPerm();
        return;
      }
      await p.setBool(_kAskedPerm, true);
      final ok = await _ch.invokeMethod<bool>('ensurePermission') ?? false;
      granted.value = ok;
      if (!ok) denied.value = true;
    } catch (_) {
      /* 老系统 / 通道异常：当没权限处理，通知不发但不崩 */
    }
  }

  Future<bool> _hasPerm() async {
    try {
      return await _ch.invokeMethod<bool>('hasPermission') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 原生异步回来的授权结果（MainActivity.onRequestPermissionsResult → Dart）
  void onPermissionResult(bool ok) {
    granted.value = ok;
    if (!ok) denied.value = true;
  }

  /// 登出 / 切企业：清状态、撤通知。不清的话下一个人登进来会看到
  /// 上一个人的未读角标和通知栏消息。监听也摘掉，等下次登录 [arm] 重挂。
  void reset() {
    detach();
    myId = 0;
    _openConv = null;
    _badgeNumber = 0;
    _convTitles.clear();
    _convTypes.clear();
    _mutedConvs.clear();
    _userNames.clear();
    tap.value = null;
    unawaited(_invoke('cancelAll'));
  }

  /// 摘监听（登出时）。再挂走 [attach]（arm 会调，幂等）。
  void detach() {
    _sub?.cancel();
    _sub = null;
    _attached = false;
    Badges.instance.unread.removeListener(_onUnreadChanged);
  }

  // ---------------- 外部输入 ----------------

  void setForeground(bool v) {
    if (_foreground == v) return;
    _foreground = v;
    // 回前台且没有未读了 → 撤掉通知栏残留（消息可能在电脑上已经读掉了）。
    // 还有未读时不撤：那些通知是"没读的消息"，该挂着。
    if (v && Badges.instance.unread.value <= 0) {
      _badgeNumber = 0;
      unawaited(_invoke('cancelAll'));
    }
  }

  /// 用户打开了某个会话（聊天页 initState 调；离开传 null）。
  /// 顺手撤掉这个会话的通知 —— 人都点进来了，通知栏那条已经是旧闻。
  void setOpenConversation(int? convId) {
    _openConv = convId;
    if (convId != null) unawaited(_invoke('cancelFor', {'conversationId': convId}));
  }

  /// 会话列表页加载完后喂进来：标题、类型、免打扰标记
  void noteConversations(List<Conversation> convs) {
    for (final c in convs) {
      if (c.title != null && c.title!.isNotEmpty) _convTitles[c.id] = c.title!;
      _convTypes[c.id] = c.type;
      if (c.muted) {
        _mutedConvs.add(c.id);
      } else {
        _mutedConvs.remove(c.id);
      }
    }
  }

  /// 聊天页渲染消息时喂进来：发送者名字（群聊通知正文要「张三: 内容」）
  void noteUser(int userId, String name) {
    if (userId <= 0 || name.trim().isEmpty) return;
    _userNames[userId] = name.trim();
  }

  // ---------------- 核心逻辑 ----------------

  void _onFrame(dynamic e) {
    if (e is! Map) return;
    if (e['type'] != 'message:new') return;
    final raw = e['message'];
    if (raw is! Map) return;
    final m = Message.fromJson(Map<String, dynamic>.from(raw));
    if (!shouldNotify(
      fromMe: myId > 0 && m.senderId == myId,
      deleted: m.deleted,
      muted: _mutedConvs.contains(m.conversationId),
      foreground: _foreground,
      openConversationId: _openConv,
      conversationId: m.conversationId,
    )) {
      return;
    }
    unawaited(_show(m));
  }

  /// 判定「这条消息该不该弹通知」—— 抽成静态纯函数，单测直接打
  /// （不依赖 socket / 平台通道，测试里进不去那两个）。
  @visibleForTesting
  static bool shouldNotify({
    required bool fromMe,
    required bool deleted,
    required bool muted,
    required bool foreground,
    required int? openConversationId,
    required int conversationId,
  }) {
    if (fromMe) return false; // 自己（含自己其他设备）发的不通知
    if (deleted) return false; // 已撤回的不通知
    if (muted) return false; // 免打扰会话：用户说了不想被打扰
    // 正在看这个会话 → 弹通知纯属打扰
    if (foreground && openConversationId == conversationId) return false;
    return true;
  }

  /// 消息正文的预览文案（按类型给占位，别把 base64 / 路径糊到通知上）
  @visibleForTesting
  static String previewOf(Message m) {
    switch (m.kind) {
      case 'image':
        return '[图片]';
      case 'audio':
        return '[语音]';
      case 'file':
        final n = (m.fileName ?? '').trim();
        return n.isNotEmpty ? '[文件] $n' : '[文件]';
      case 'card':
        return '[名片]';
      case 'emoji':
        return '[表情]';
      default:
        return (m.content ?? '').trim();
    }
  }

  Future<void> _show(Message m) async {
    final title = _titleFor(m);
    final body = _bodyFor(m);
    // 角标数 = 自己数的 +1，与服务端真值（会话页拉列表后写入）取大。
    // 为什么不直接用 Badges：那条是异步刷新，本帧到达时可能还是旧值
    // （连来两条时第二条会少算 1）。
    final server = Badges.instance.unread.value;
    _badgeNumber = (_badgeNumber + 1 > server) ? _badgeNumber + 1 : server;
    await _invoke('showMessage', {
      'conversationId': m.conversationId,
      'title': title,
      'body': body,
      'number': _badgeNumber,
      // 后台到达才震+弹条；前台由提示音负责响，通知只更新角标
      'mode': _foreground ? 'quiet' : 'alert',
    });
  }

  String _titleFor(Message m) {
    final t = _convTitles[m.conversationId];
    if (t != null && t.isNotEmpty) return t;
    return '新消息';
  }

  String _bodyFor(Message m) {
    final preview = previewOf(m);
    final isGroup = _convTypes[m.conversationId] == 'group';
    final sender = _userNames[m.senderId];
    if (isGroup && sender != null && sender.isNotEmpty) {
      return '$sender: $preview';
    }
    return preview.isEmpty ? '新消息' : preview;
  }

  void _onUnreadChanged() {
    final n = Badges.instance.unread.value;
    if (n <= 0) {
      _badgeNumber = 0;
      unawaited(_invoke('cancelAll'));
    } else if (n > _badgeNumber) {
      _badgeNumber = n; // 服务端真值更高（电脑上攒了更多未读），跟上
    }
  }

  // ---------------- 通知栏点击 ----------------

  /// 原生推来的点击（App 活着时）或冷启动取到的点击
  void _onTap(int convId) {
    if (convId <= 0) return;
    tap.value = convId;
  }

  /// Dart 侧热启动入口：原生 invokeMethod('onNotificationTap', convId)
  void onNativeTap(dynamic convId) {
    final c = convId is int ? convId : int.tryParse('$convId') ?? 0;
    _onTap(c);
  }

  /// 会话页消费点击（返回后清零，避免返回时又跳一次）
  int? consumeTap() {
    final c = tap.value;
    tap.value = null;
    return c;
  }

  // ---------------- 工具 ----------------

  Future<void> _invoke(String method, [Map<String, dynamic>? args]) async {
    if (!Platform.isAndroid) return;
    try {
      await _ch.invokeMethod(method, args);
    } catch (_) {
      // 通知发不出去不该影响聊天主流程（老系统 / 通道异常）
    }
  }
}
