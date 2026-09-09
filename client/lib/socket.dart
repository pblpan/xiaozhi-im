import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'core/config.dart';
import 'core/storage.dart';

/// WebSocket 实时通道：仅用于接收服务端推送（消息/好友/群事件）
class SocketService {
  static final SocketService _i = SocketService._();
  factory SocketService() => _i;
  SocketService._();

  WebSocketChannel? _ch;
  final _ctrl = StreamController<dynamic>.broadcast();
  Stream<dynamic> get stream => _ctrl.stream;

  Future<void> connect() async {
    final t = await Storage.getToken();
    if (t == null) return;
    _ch = WebSocketChannel.connect(Uri.parse('${Config.wsUrl}/ws?token=$t'));
    _ch!.stream.listen(
      (e) {
        try {
          _ctrl.add(jsonDecode(e));
        } catch (_) {}
      },
      onError: (_) {},
      onDone: () {},
    );
  }

  void send(Map<String, dynamic> frame) => _ch?.sink.add(jsonEncode(frame));

  void disconnect() {
    _ch?.sink.close();
    _ch = null;
  }
}
