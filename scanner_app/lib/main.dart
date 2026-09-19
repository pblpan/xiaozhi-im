import 'package:flutter/material.dart';

import 'core/scan_feedback.dart';
import 'core/theme.dart';
import 'screens/stocktake.dart';

/// 小智扫码枪（独立 App）入口。
///
/// ── 为什么这个 App 没有登录页 ────────────────────────────────
/// 它是给**站在货架之间的员工**用的。那台手机上不该有"输服务器地址、
/// 输账号密码"这一步 —— 他不知道 IP 是什么，也不会想在冷柜旁边登什么。
/// 所以打开就是采集页，商档靠导一份 CSV 进来，导出直接走系统分享面板
/// 发给同事。整条链一次网络请求都不发。
///
/// ── 为什么要在 runApp 之前 init 提示音 ──────────────────────
/// 员工靠"嘀"这一声确认扫上了才敢扫下一件。AudioPlayer 第一次播 asset
/// 要走一轮 rootBundle 解码，实测 100~300ms —— 不预加载的话第一枪
/// 慢半拍，员工会以为没扫上、于是重复扫（件数就这么虚高了）。
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ScanFeedbackService.I.init();
  runApp(const ScannerApp());
}

class ScannerApp extends StatelessWidget {
  const ScannerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '小智扫码枪',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      home: const StocktakePage(),
    );
  }
}
