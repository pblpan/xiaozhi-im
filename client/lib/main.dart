import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'api.dart';
import 'core/call_service.dart';
import 'core/remote_config.dart';
import 'core/settings.dart';
import 'core/sound_service.dart';
import 'core/storage.dart';
import 'core/theme.dart';
import 'screens/login.dart';
import 'screens/conversations.dart';
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
  await RemoteConfig().init(); // 配置中心：先吃本地缓存，再后台拉最新（含地址候选）
  await ImApi().restore(); // 冷启动恢复登录态（否则请求全 401）
  await SoundService().init(); // 读提示音开关 + 预加载音频
  SoundService().attach(); // 全局监听新消息，收到就响一声
  CallService().navKey = appNavigatorKey;
  await CallService().attach(); // 订阅通话信令，随时能接来电
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: '小智 IM',
        navigatorKey: appNavigatorKey,
        theme: AppTheme.dark(),
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
    return _has! ? const ConversationsScreen() : const LoginScreen();
  }
}
