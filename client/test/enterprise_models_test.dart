import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/config.dart';
import 'package:xiaozhi_im_client/core/server_profile.dart';

/// 多企业改造（龙哥 2026-10-01）的纯逻辑单测。
///
/// 这些用例不碰网络、不碰 SharedPreferences，可在 CI 的 `flutter test` 里稳定跑。
/// SessionManager 的运行时行为（切换 / 后台连接 / 角标）涉及 WS 与 HTTP，留待 CI
/// 集成校验（本机 Dart 子进程被拦截，无法本地跑 `flutter test`）。
void main() {
  group('ServerProfile JSON 往返', () {
    test('含 token 的档案往返一致', () {
      final p = ServerProfile(
        id: 'a-1',
        name: 'B小智',
        lan: 'http://192.168.1.9:3602',
        wan: 'https://b.example.com',
        mode: Config.modeAuto,
        token: 'jwt-xyz',
        currentUrl: 'http://192.168.1.9:3602',
        active: true,
      );
      final q = ServerProfile.fromJson(p.toJson());
      expect(q.id, 'a-1');
      expect(q.name, 'B小智');
      expect(q.lan, 'http://192.168.1.9:3602');
      expect(q.wan, 'https://b.example.com');
      expect(q.mode, Config.modeAuto);
      expect(q.token, 'jwt-xyz');
      expect(q.currentUrl, 'http://192.168.1.9:3602');
      expect(q.active, true);
    });

    test('缺省字段往返安全（token/currentUrl 可空）', () {
      final p = ServerProfile(
        id: 'b-2',
        name: '小智',
        lan: 'http://10.0.0.1:3602',
        wan: '',
        mode: Config.modeLan,
      );
      final q = ServerProfile.fromJson(p.toJson());
      expect(q.token, isNull);
      expect(q.currentUrl, isNull);
      expect(q.active, isFalse);
    });

    test('newId 不重复', () {
      final a = ServerProfile.newId();
      final b = ServerProfile.newId();
      expect(a, isNot(equals(b)));
    });
  });

  group('Config 地址工具', () {
    test('normalize 补全 scheme，去尾斜杠', () {
      expect(Config.normalize('192.168.1.9:3602'),
          'http://192.168.1.9:3602');
      expect(Config.normalize('http://x/'), 'http://x');
      expect(Config.normalize(''), '');
    });

    test('wsFrom 由 http(s) 推导 ws(s)', () {
      expect(Config.wsFrom('http://1.2.3.4:3602'), 'ws://1.2.3.4:3602');
      expect(Config.wsFrom('https://x.io'), 'wss://x.io');
    });

    test('三档网络模式常量', () {
      expect(Config.modeAuto, 'auto');
      expect(Config.modeLan, 'lan');
      expect(Config.modeWan, 'wan');
    });
  });
}
