import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xiaozhi_im_client/core/call_service.dart';
import 'package:xiaozhi_im_client/core/config.dart';
import 'package:xiaozhi_im_client/main.dart';

/// 启动冒烟测试。
///
/// 原来这里是 Flutter 脚手架的计数器模板测试（找一个不存在的 '+' 按钮），
/// 从来没适配过本项目、一直是红的。换成真正有价值的断言：
/// ① 冷启动能落到登录页；② 通话引擎初始处于空闲、不误触发来电界面。
///
/// ⚠️ 2026-09-16 客户端加固后，"冷启动落到哪儿"变成**两分支**：
///    · 已配过服务器 → 登录页
///    · 一个地址都没有（新装 + 局域网没扫到）→ 首次使用引导页 SetupServerScreen
///    加固前安装包里写死着生产地址，所以必然走第一条分支，测试也一直是按
///    "必然能到登录页"写的。现在地址必须由运行期提供，测试里就得自己给。
///
/// ⚠️ 注意本文件**不走 main()**（直接 pumpWidget(MyApp())），所以
///    Settings.load() 不会执行 —— 想模拟"已配置服务器"只能直接改 Config
///    的静态字段，改 SharedPreferences 是没用的（那条路压根没人读）。
void main() {
  /// 模拟"已经把服务器配好了"：加固后除新装之外的常态。
  /// 用 TEST-NET-1（RFC 5737 专门给文档/测试用的地址段），不是任何真实服务器。
  void withConfiguredServer() {
    Config.lanUrl = 'http://192.0.2.10:3602';
    Config.wanUrl = '';
    Config.currentUrl = 'http://192.0.2.10:3602';
  }

  void withNoServer() {
    Config.lanUrl = '';
    Config.wanUrl = '';
    Config.currentUrl = '';
  }

  testWidgets('未登录时冷启动进入登录页（已配置服务器）', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({}); // 无 token
    withConfiguredServer();
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();

    expect(find.text('小智 IM'), findsOneWidget);
    expect(find.text('登录到你的私有通讯'), findsOneWidget);
  });

  testWidgets('登录页有账号密码输入与注册入口', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    withConfiguredServer();
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();

    expect(find.text('账号'), findsOneWidget);
    expect(find.text('密码'), findsOneWidget);
    expect(find.text('立即注册'), findsOneWidget);
  });

  /// 新增（v0.14.0）：**没有任何服务器地址时不许把用户丢在登录页**。
  /// 加固后安装包不再内置地址，"新装 + 局域网没扫到"是真实存在的状态；
  /// 停在登录页只会让用户反复点登录、只看到"网络错误"，却不知道该干什么。
  /// 这条断言守的就是"必须给一个能自助解决的出口"。
  ///
  /// ⚠️ 这里**不用 pumpAndSettle**：引导页进来就会发起局域网扫描（UDP + 2s 超时），
  ///    在测试的假时钟里等它"settle"要么等不到、要么拖到超时。
  ///    只 pump 到第一帧就够断言了（标题在首帧就在）。
  testWidgets('没有服务器地址时进首次使用引导页（不是登录页）', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    withNoServer();
    await tester.pumpWidget(const MyApp());
    await tester.pump();

    expect(find.text('连接你的服务器'), findsOneWidget);
    expect(find.text('手动填写服务器地址'), findsOneWidget);
    // 反面：绝不能是登录页 —— 否则用户只能对着"网络错误"发呆
    expect(find.text('登录到你的私有通讯'), findsNothing);
  });

  /// 纯逻辑判据：把"未配置"这件事的判定本身钉住。
  /// 上层（AuthGate）就是靠它决定要不要显示引导页，判错了用户就卡住。
  test('地址为空时判定为未配置，有地址时判定为已配置', () {
    withNoServer();
    expect(Config.configured, isFalse);
    withConfiguredServer();
    expect(Config.configured, isTrue);
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
