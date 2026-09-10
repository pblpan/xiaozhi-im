import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xiaozhi_im_client/core/call_service.dart';
import 'package:xiaozhi_im_client/main.dart';

/// 启动冒烟测试。
///
/// 原来这里是 Flutter 脚手架的计数器模板测试（找一个不存在的 '+' 按钮），
/// 从来没适配过本项目、一直是红的。换成真正有价值的断言：
/// ① 冷启动能落到登录页；② 通话引擎初始处于空闲、不误触发来电界面。
void main() {
  testWidgets('未登录时冷启动进入登录页', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({}); // 无 token
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();

    expect(find.text('小智 IM'), findsOneWidget);
    expect(find.text('登录到你的私有通讯'), findsOneWidget);
  });

  testWidgets('登录页有账号密码输入与注册入口', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();

    expect(find.text('账号'), findsOneWidget);
    expect(find.text('密码'), findsOneWidget);
    expect(find.text('立即注册'), findsOneWidget);
  });

  test('通话引擎初始为空闲状态', () {
    final c = CallService();
    expect(c.phase.value, CallPhase.idle);
    expect(c.session.value, isNull);
    expect(c.micOn.value, isTrue);
    expect(c.seconds.value, 0);
  });

  test('ICE 配置非空且带 urls', () {
    expect(kIceServers, isNotEmpty);
    for (final s in kIceServers) {
      expect(s['urls'], isNotNull);
    }
  });
}
