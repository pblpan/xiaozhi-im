import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'api.dart';
import 'core/call_service.dart';
import 'core/config.dart';
import 'core/integrity.dart';
import 'core/remote_config.dart';
import 'screens/remote.dart';
import 'core/settings.dart';
import 'core/share_intake.dart';
import 'core/sound_service.dart';
import 'core/storage.dart';
import 'core/theme.dart';
import 'core/tray_service.dart';
import 'core/workspace.dart';
import 'screens/home_shell.dart';
import 'screens/login.dart';
import 'screens/setup_server.dart';
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
  // 包完整性自校验：被改过/被重签名的安装包，直接不给进入。
  // ⚠️ 位置讲究：必须在 ensureInitialized() **之后**（MethodChannel 的前置条件，
  //    跟 ShareIntake 那次一启动就崩是同一个坑），又在任何网络请求之前。
  await Integrity.check();

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
  // 系统「分享到小智」的入口（仅 Android）。**故意不 await**：分享进来的图可能几十 MB，
  // 拷贝耗时，不该卡住启动；拷完会通过 ShareIntake.pending 通知首页去接手。
  // 桌面端内部直接跳过（Platform.isAndroid 为 false），不会去调不存在的原生通道。
  ShareIntake.init();
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
        // 完整性校验没过就**不进入** App：挡在最外层，连登录页都不给。
        // 这是唯一一个"不给绕过"的界面 —— 签名对不上意味着这个包不可能是我们出的。
        home: Integrity.blocked != null
            ? IntegrityBlockedScreen(reason: Integrity.blocked!)
            : const AuthGate(),
        debugShowCheckedModeBanner: false,
      );
}

/// 被篡改时的阻断页（无跳过入口）。
class IntegrityBlockedScreen extends StatelessWidget {
  final String reason;
  const IntegrityBlockedScreen({super.key, required this.reason});

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: AppColors.bg,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.gpp_bad_rounded,
                      size: 56, color: AppColors.danger),
                  const SizedBox(height: 18),
                  Text(
                    reason,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: AppColors.text,
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    '请从官方安装包重新安装后再使用。\n'
                    '（出现这个提示说明程序文件被改动过，出于安全考虑已停止运行）',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 13, height: 1.7, color: AppColors.textSub),
                  ),
                  if (Integrity.detail != null) ...[
                    const SizedBox(height: 18),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.surface,
                        borderRadius: BorderRadius.circular(AppRadii.sm),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: Text(
                        Integrity.detail!,
                        style: const TextStyle(
                            fontSize: 11,
                            height: 1.6,
                            fontFamily: 'monospace',
                            color: AppColors.textWeak),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
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
    // 还不知道该连哪台服务器（加固后包里不再内置地址；局域网也没扫到）
    // → 引导用户去发现/手填，别把他丢在登录页反复看"网络错误"。
    if (!Config.configured) {
      return SetupServerScreen(onConfigured: _check);
    }
    return _has! ? const HomeShell() : const LoginScreen();
  }
}
