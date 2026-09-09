import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'api.dart';
import 'core/settings.dart';
import 'core/storage.dart';
import 'core/theme.dart';
import 'screens/login.dart';
import 'screens/conversations.dart';
import 'widgets/avatar.dart';

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
  await ImApi().restore(); // 冷启动恢复登录态（否则请求全 401）
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: '小智 IM',
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
