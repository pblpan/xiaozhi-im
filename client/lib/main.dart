import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'api.dart';
import 'core/call_service.dart';
import 'core/remote_config.dart';
import 'screens/remote.dart';
import 'core/settings.dart';
import 'core/sound_service.dart';
import 'core/storage.dart';
import 'core/theme.dart';
import 'core/tray_service.dart';
import 'core/workspace.dart';
import 'screens/home_shell.dart';
import 'screens/login.dart';
import 'widgets/avatar.dart';

/// 全局导航 key：来电时用户可能在任意页面（甚至聊天页里），
/// 通话引擎靠它把全屏通话页推到最上层。
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isAndroid) {
    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.light,
      systemNavigationBarColor: AppColors.bg,
      systemNavigationBarIconBrightness: Brightness.light,
    ));
  }
  await Settings.load(); // 载入用户自定义的服务器地址
  // 好友模式（普通/工作）+ 公司名：主界面靠它决定导航形态（工作模式才有
  // 工作台/组织通讯录的一级入口）。先吃本地缓存保证离线也能定形态，
  // 网络那次在后台拉，不阻塞启动。
  await Workspace.load();
  await RemoteConfig().init(); // 配置中心：先吃本地缓存，再后台拉最新（含地址候选）
  await ImApi().restore(); // 冷启动恢复登录态（否则请求全 401）
  await SoundService().init(); // 读提示音开关 + 预加载音频
  SoundService().attach(); // 全局监听新消息，收到就响一声
  CallService().navKey = appNavigatorKey;
  await CallService().attach(); // 订阅通话信令，随时能接来电
  // 桌面端：托盘 + "关闭=缩到托盘"，必须赶在 runApp 之前装好拦截，
  // 否则用户可能在监听还没挂上的那半秒里把窗口关掉（这时程序会真的退出）。
  // 来电要把缩在托盘里的窗口拉回来，所以先把导航 key 交出去。
  TrayService.instance.attachNavigator(appNavigatorKey);
  await TrayService.instance.init();
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

/// 监听 App 生命周期：回到前台时重拉一次服务器模式。
///
/// 覆盖一个此前漏掉的时序：管理员在管理台把服务器切成工作模式、用户只是把 App
/// 切回前台（没杀进程重启），旧逻辑不会重新拉取，导航形态就停在旧模式 —— 工作台 /
/// 组织通讯录入口出不来。回到前台补一发，配合 Workspace.refresh() 自身的重试，
/// "服务端改了模式，客户端马上跟上"才稳。
class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) Workspace.refresh();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: '小智 IM',
        navigatorKey: appNavigatorKey,
        theme: AppTheme.dark(),
        // 挂在 builder 而不是包某一条路由：协作请求必须**在任何页面之上**
        // 弹出来（用户在聊天页里照样要能看到），"正在被协助"的警示条同理。
        // 包 login 或 home 都做不到 —— 一旦 push 了新路由就盖不住了。
        builder: (ctx, child) =>
            RemoteAssistWatcher(child: child ?? const SizedBox.shrink()),
        home: const AuthGate(),
        debugShowCheckedModeBanner: false,
      );
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});
  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  bool? _has;
  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final t = await Storage.getToken();
    if (mounted) setState(() => _has = t != null && t.isNotEmpty);
  }

  @override
  Widget build(BuildContext context) {
    if (_has == null) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              BrandLogo(size: 64),
              SizedBox(height: 20),
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ],
          ),
        ),
      );
    }
    return _has! ? const HomeShell() : const LoginScreen();
  }
}
