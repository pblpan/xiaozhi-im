import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'core/config.dart';
import 'core/storage.dart';

enum ConnState { idle, connecting, online, offline }

/// WebSocket 实时通道：仅用于接收服务端推送（消息/好友/群事件）
/// 断线自动重连（指数退避，最多 12 次），切换服务器后调用 reconnect()
class SocketService {
  static final SocketService _i = SocketService._();
  factory SocketService() => _i;
  SocketService._();

  WebSocketChannel? _ch;
  final _ctrl = StreamController<dynamic>.broadcast();
  Stream<dynamic> get stream => _ctrl.stream;

  /// 连接状态，界面可监听显示"连接中/已连接/已断开"
  final ValueNotifier<ConnState> state = ValueNotifier(ConnState.idle);

  Timer? _retry;
  int _tries = 0;
  bool _closedByUs = false;

  Future<void> connect() async {
    final t = await Storage.getToken();
    if (t == null) return;
    _open(t);
  }

  void _open(String token) {
    _ch?.sink.close();
    state.value = ConnState.connecting;
    try {
      _ch = WebSocketChannel.connect(
          Uri.parse('${Config.wsUrl}/ws?token=$token'));
      _ch!.stream.listen(
        (e) {
          _tries = 0;
          if (state.value != ConnState.online) state.value = ConnState.online;
          try {
            _ctrl.add(jsonDecode(e));
          } catch (_) {}
        },
        onError: (_) => _scheduleRetry(),
        onDone: () => _scheduleRetry(),
      );
    } catch (_) {
      _scheduleRetry();
    }
  }

  void _scheduleRetry() {
    if (_closedByUs) return;
    if (state.value != ConnState.offline) state.value = ConnState.offline;
    _retry?.cancel();
    if (_tries >= 12) return;
    final wait = switch (_tries) {
      0 => 1,
      1 => 2,
      2 => 4,
      _ => 8,
    };
    _tries++;
    _retry = Timer(Duration(seconds: wait), () async {
      final t = await Storage.getToken();
      if (t == null || _closedByUs) return;
      _open(t);
    });
  }

  /// 手动重连（例如切换服务器地址后）
  Future<void> reconnect() async {
    _retry?.cancel();
    _tries = 0;
    _closedByUs = false;
    await connect();
  }

  void send(Map<String, dynamic> frame) => _ch?.sink.add(jsonEncode(frame));

  void disconnect() {
    _closedByUs = true;
    _retry?.cancel();
    _ch?.sink.close();
    _ch = null;
    state.value = ConnState.idle;
  }
}
