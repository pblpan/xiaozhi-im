import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'config.dart';
import 'server_profile.dart';
import 'session_manager.dart';
import '../socket.dart';

/// 非激活企业的后台长连接。
///
/// 作用（龙哥 2026-10-01 需求）：每家企业在后台都保持一条 WS，**只为收推送**——
/// 收到 `message:new` 累加到该企业的未读数，收到 `friend:pending` 更新待处理申请数，
/// 并上报连接状态（供切换器显示"在链接状态"）。它**不参与**发业务、不弹通话/远程，
/// 那些只走激活企业的 [SocketService]。
///
/// 健壮性沿用 [SocketService] 的思路（无限重连 + 心跳 + 看门狗），但更轻：
/// 后台连接断了顶多晚几秒收到提醒，不会像激活连接那样"收不到来电"。
class _BgLink {
  final ServerProfile profile;
  final void Function(ConnState) onState;
  final void Function() onMessage;
  final void Function(int) onPending;

  _BgLink(this.profile,
      {required this.onState, required this.onMessage, required this.onPending});

  WebSocketChannel? _ch;
  StreamSubscription<dynamic>? _sub;
  Timer? _retry;
  Timer? _hb;
  DateTime? _last;
  int _tries = 0;
  bool _closed = false;
  ConnState _state = ConnState.idle;

  static const _hbEvery = Duration(seconds: 25);
  static const _deadAfter = Duration(seconds: 60);

  void _setState(ConnState s) {
    _state = s;
    onState(s);
  }

  void start() {
    _closed = false;
    _open();
  }

  void stop() {
    _closed = true;
    _retry?.cancel();
    _hb?.cancel();
    _sub?.cancel();
    _sub = null;
    try {
      _ch?.sink.close();
    } catch (_) {
      /* 已关闭 */
    }
    _ch = null;
    _setState(ConnState.idle);
  }

  Future<void> _open() async {
    if (_closed) return;
    final token = profile.token;
    if (token == null || token.isEmpty) {
      // 还没登录：标离线，稍后（登录后）再被 sync 拉起
      _setState(ConnState.offline);
      _scheduleRetry(immediate: true);
      return;
    }
    final http = await Config.pickFor(profile.lan, profile.wan, profile.mode);
    if (http.isEmpty) {
      _setState(ConnState.offline);
      _scheduleRetry(immediate: true);
      return;
    }
    try {
      _setState(ConnState.connecting);
      _last = DateTime.now();
      final ch = WebSocketChannel.connect(
          Uri.parse('${Config.wsFrom(http)}/ws?token=$token'));
      _ch = ch;
      _sub = ch.stream.listen(
        (e) {
          _last = DateTime.now();
          _tries = 0;
          if (_closed) return;
          if (_state != ConnState.online) _setState(ConnState.online);
          try {
            final m = jsonDecode(e);
            if (m is! Map) return;
            final type = m['type'];
            if (type == 'message:new') {
              onMessage();
            } else if (type == 'friend:pending') {
              final req = m['requests'];
              final n = req is List ? req.length : 0;
              onPending(n);
            }
          } catch (_) {
            /* 非 JSON 帧忽略 */
          }
        },
        onError: (_) => _scheduleRetry(),
        onDone: () => _scheduleRetry(),
        cancelOnError: true,
      );
      _startHb();
    } catch (_) {
      _scheduleRetry();
    }
  }

  void _startHb() {
    _hb?.cancel();
    _hb = Timer.periodic(_hbEvery, (_) {
      if (_closed) return;
      final last = _last;
      if (last != null && DateTime.now().difference(last) > _deadAfter) {
        _hardReconnect();
        return;
      }
      try {
        _ch?.sink.add(jsonEncode(
            {'type': 'ping', 'ts': DateTime.now().millisecondsSinceEpoch}));
      } catch (_) {
        _scheduleRetry();
      }
    });
  }

  void _hardReconnect() {
    _hb?.cancel();
    _sub?.cancel();
    _sub = null;
    try {
      _ch?.sink.close();
    } catch (_) {
      /* ignore */
    }
    _ch = null;
    _setState(ConnState.offline);
    _open();
  }

  void _scheduleRetry({bool immediate = false}) {
    if (_closed) return;
    _hb?.cancel();
    _retry?.cancel();
    _setState(ConnState.offline);
    final wait = immediate
        ? 2
        : switch (_tries) {
            0 => 3,
            1 => 6,
            2 => 12,
            _ => 20,
          };
    if (_tries < 4) _tries++;
    _retry = Timer(Duration(seconds: wait), () => _open());
  }
}

/// 所有非激活企业的后台连接总管。
///
/// 监听 [SessionManager] 的档案变化（profilesVersion / domainVersion），
/// 自动为"非激活且有 token"的档案建立/销毁后台连接。
class BackgroundLinkService {
  static final BackgroundLinkService instance = BackgroundLinkService._();
  BackgroundLinkService._();

  final Map<String, _BgLink> _links = {};
  bool _started = false;

  void start() {
    if (_started) return;
    _started = true;
    SessionManager.instance.profilesVersion.addListener(_sync);
    SessionManager.instance.domainVersion.addListener(_sync);
    _sync();
  }

  /// 手动触发一次同步（登录成功后调用，确保新档案立刻连上）。
  void sync() => _sync();

  void _sync() {
    final sm = SessionManager.instance;
    final activeId = sm.activeId;
    final desired = <String>{};
    for (final pr in sm.profiles) {
      if (pr.id != activeId && pr.token != null && pr.token!.isNotEmpty) {
        desired.add(pr.id);
        if (!_links.containsKey(pr.id)) {
          final link = _BgLink(
            pr,
            onState: (s) => sm.linkStateOf(pr.id).value = s,
            onMessage: () {
              final b = sm.badgesOf(pr.id);
              b.unread.value = b.unread.value + 1;
              sm.notifyBackgroundChange(); // 主页面提醒条立刻刷新
            },
            onPending: (n) {
              sm.badgesOf(pr.id).pending.value = n;
              sm.notifyBackgroundChange();
            },
          );
          _links[pr.id] = link;
          link.start();
        }
      }
    }
    // 移除不再需要的连接（已激活 / 已删除 / 已登出）
    final toRemove = _links.keys.where((id) => !desired.contains(id)).toList();
    for (final id in toRemove) {
      _links.remove(id)?.stop();
    }
  }

  /// 全部断开（退出登录等）。
  void stopAll() {
    for (final l in _links.values) l.stop();
    _links.clear();
  }
}
