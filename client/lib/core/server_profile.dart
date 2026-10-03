import 'dart:math';
import 'config.dart';

/// 一家企业（一个独立部署的小智服务器）的连接档案。
///
/// 为什么需要这一层：以前客户端是"单服务器单账号"——`Config` 里只有一组
/// lan/wan/mode、`Storage` 里只有一份 token。现在要支持"按企业分组、多台服务器、
/// 各自账号、整域切换"（龙哥 2026-10-01 需求），就得把"连哪台、用哪个账号"从
/// 全局单例变成可枚举、可持久化、可切换的档案列表。
///
/// 每个档案自带 lan/wan/mode（沿用既有双地址 + 自动探测语义）和该企业的登录 token。
/// 两个地址都要保持"在链接状态"——激活企业走 [SocketService]（带心跳/看门狗），
/// 非激活企业走 [BackgroundLinkService]（轻量长连接，只为收推送）。
class ServerProfile {
  /// 档案唯一 id（本地生成，不上服务端）。
  final String id;

  /// 企业名（界面显示，如"A小智""B小智"）。
  String name;

  /// 内网地址（办公网）。
  String lan;

  /// 外网地址（出差/在家）。可为空。
  String wan;

  /// 网络模式：auto | lan | wan。
  String mode;

  /// 该企业的登录 token（JWT）。null = 还没登录。
  String? token;

  /// 探测后解析出的当前实际地址（lan/wan 之一），用于快速判断"连的是哪台"。
  String? currentUrl;

  /// 是否为当前激活企业（整域切换的目标）。
  bool active;

  ServerProfile({
    required this.id,
    required this.name,
    required this.lan,
    required this.wan,
    required this.mode,
    this.token,
    this.currentUrl,
    this.active = false,
  });

  /// 本地生成唯一 id：时间戳 + 随机数，足够避免本地多档案碰撞。
  static String newId() {
    final r = Random();
    return '${DateTime.now().microsecondsSinceEpoch}-${r.nextInt(1000000)}';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'lan': lan,
        'wan': wan,
        'mode': mode,
        if (token != null) 'token': token,
        if (currentUrl != null) 'currentUrl': currentUrl,
        'active': active,
      };

  factory ServerProfile.fromJson(Map<String, dynamic> j) => ServerProfile(
        id: j['id']?.toString() ?? newId(),
        name: j['name']?.toString() ?? '小智',
        lan: j['lan']?.toString() ?? '',
        wan: j['wan']?.toString() ?? '',
        mode: j['mode']?.toString() ?? Config.modeAuto,
        token: j['token']?.toString(),
        currentUrl: j['currentUrl']?.toString(),
        active: j['active'] == true,
      );

  /// 两地址都规范化为 http(s):// 开头。
  void normalizeAddresses() {
    lan = Config.normalize(lan);
    wan = Config.normalize(wan);
  }
}
