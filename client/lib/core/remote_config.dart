import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import 'app_version.dart';
import 'config.dart';
import 'settings.dart';

// re-export：历史代码从 remote_config.dart 里 import 版本号，保持可用
export 'app_version.dart' show kAppVersion;

/// 客户端配置服务（SPEC-动态配置与模块.md 第一期）
///
/// 铁律（见 SPEC §6.2）：配置下发是"锦上添花"的能力，它出问题绝不能让 App
/// 不可用。所以本类所有异常路径都以"保持现状"收场 —— 网络失败静默、payload
/// 解析失败静默、单项数据不合法跳过该项。**这里抛出异常就是写错了。**
class RemoteConfig {
  static final RemoteConfig _i = RemoteConfig._();
  factory RemoteConfig() => _i;
  RemoteConfig._();

  static const _kCache = 'xz_remote_config'; // 上次成功应用的 payload JSON
  static const _kVer = 'xz_remote_config_ver'; // 对应版本号
  static const _kDevice = 'xz_device_id'; // 设备标识（上报同步状态用）
  static const Duration pollInterval = Duration(minutes: 30);
  static const Duration fetchTimeout = Duration(seconds: 6);

  /// 当前已应用的配置版本（0 = 从未拿到过）
  int appliedVersion = 0;

  /// 当前生效的 payload（保持 SPEC §5 的顶层结构）
  Map<String, dynamic> payload = {};

  Timer? _timer;
  String? _deviceId;

  /// 配置变化事件：UI（公告横幅等）监听它自行刷新
  final ValueNotifier<int> changed = ValueNotifier<int>(0);

  /// 最低版本不满足时的提示文案；null = 版本没问题
  final ValueNotifier<String?> upgradeHint = ValueNotifier<String?>(null);

  /// 当前平台可用的直装包地址（已拼成绝对地址）；null = 没有对应平台的直装包
  final ValueNotifier<String?> upgradePackageUrl = ValueNotifier<String?>(null);

  /// 通用升级说明页地址（已拼成绝对地址）；null = 没有
  final ValueNotifier<String?> upgradePageUrl = ValueNotifier<String?>(null);

  bool featureOn(String name, {bool def = true}) {
    final f = payload['features'];
    if (f is Map && f[name] is bool) return f[name] as bool;
    return def;
  }

  /// 拉取 bootstrap 顶层的公开字段（companyName / friendMode / serverVersion）。
  /// 登录前就要用（登录页标题、注册页工作模式提示），所以单独走一次轻量请求。
  /// 任何失败返回空 Map —— 这里抛异常就是写错了（SPEC §6.2 同款纪律）。
  static Future<Map<String, dynamic>> fetchPublic() async {
    try {
      final r = await http
          .get(Uri.parse('${Config.baseUrl}/api/client/bootstrap'))
          .timeout(fetchTimeout);
      if (r.statusCode != 200) return const {};
      final body = jsonDecode(r.body);
      if (body is! Map<String, dynamic>) return const {};
      return body;
    } catch (_) {
      return const {};
    }
  }

  /// 初始化：冷启动调用（在 Settings.load 之后，地址候选才有意义）
  Future<void> init() async {
    await _loadCache();
    unawaited(fetch());
    _timer?.cancel();
    _timer = Timer.periodic(pollInterval, (_) => fetch());
  }

  Future<void> dispose() async {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _loadCache() async {
    try {
      final p = await SharedPreferences.getInstance();
      appliedVersion = p.getInt(_kVer) ?? 0;
      final raw = p.getString(_kCache);
      if (raw != null && raw.isNotEmpty) {
        final decoded = jsonDecode(raw);
        if (decoded is Map<String, dynamic>) payload = decoded;
      }
    } catch (_) {
      // 缓存坏了就当没有，下一次 fetch 会覆盖
    }
  }

  /// 拉取最新配置。任何失败都静默 —— 调用方无需 try-catch。
  Future<void> fetch() async {
    try {
      final r = await http
          .get(Uri.parse('${Config.baseUrl}/api/client/bootstrap'))
          .timeout(fetchTimeout);
      if (r.statusCode != 200) return;
      final body = jsonDecode(r.body);
      if (body is! Map<String, dynamic>) return;
      final ver = body['configVersion'];
      final pl = body['payload'];
      if (ver is! int || pl is! Map<String, dynamic>) return;
      if (ver == appliedVersion) return; // 最常见路径：没变化，什么都不做
      await _apply(ver, pl);
    } catch (_) {
      // 网络失败/解析失败：保持现状。这正是 SPEC §6.2 要求的行为。
    }
  }

  /// 应用一份新配置。逐项处理，单项不合法跳过该项。
  Future<void> _apply(int ver, Map<String, dynamic> pl) async {
    try {
      final p = await SharedPreferences.getInstance();

      // ---- ① 服务器地址候选（支持字符串 或 {url,type}；含 IPv4/IPv6）----
      final addrs = pl['serverAddresses'];
      if (addrs is List && addrs.isNotEmpty && !(await Settings.hasUserServers())) {
        // 用户从没改过地址 → 跟随服务端下发；用户自己配过的优先，绝不覆盖
        final cands = Config.parseCandidates(addrs);
        if (cands.isNotEmpty) {
          Config.serverCandidates = cands;
          // 顺带把前两条写回 lan/wan，兼容任何仍读这两个字段的旧代码
          Config.lanUrl = cands.first.url;
          Config.wanUrl = cands.length > 1 ? cands[1].url : cands.first.url;
          Config.invalidateProbeCache(); // 下次重连/手动切换时用新地址，不打断当前连接
        }
      }

      // ---- ② 功能开关 / 公告 / 维护：payload 原样保留，消费方按需读 ----
      // （features 非法的键会在 featureOn() 里走默认值，不需要在这里清洗）

      // ---- ③ 版本策略 + 升级包 ----
      final minVer = pl['minClientVersion'];
      if (minVer is String && minVer.isNotEmpty && versionLess(kAppVersion, minVer)) {
        upgradeHint.value = '当前版本 $kAppVersion 过低，请升级到 $minVer 或以上';
      } else {
        upgradeHint.value = null;
      }

      // 选当前平台的直装包（android / windows / ios，都没有则 universal 兜底）
      final pkgs = pl['upgradePackages'];
      String? pkg;
      if (pkgs is Map) pkg = _pickPackage(pkgs);
      upgradePackageUrl.value = pkg != null ? _resolveUrl(pkg) : null;

      final up = pl['upgradeUrl'];
      upgradePageUrl.value = (up is String && up.trim().isNotEmpty) ? _resolveUrl(up.trim()) : null;

      // ---- ④ 落缓存 + 通知 ----
      payload = pl;
      appliedVersion = ver;
      await p.setString(_kCache, jsonEncode(pl));
      await p.setInt(_kVer, ver);
      changed.value++;

      // ---- ⑤ 上报（登录了才报；失败无所谓，下次拉取成功后还会再报） ----
      unawaited(_reportApplied(ver));
    } catch (_) {
      // 应用过程出任何意外：不落缓存、不升版本号，等下一轮重试
    }
  }

  Future<void> _reportApplied(int ver) async {
    try {
      final api = ImApi();
      if (!api.hasToken) return;
      final dev = await deviceId();
      await api.reportConfigApplied(ver, dev);
    } catch (_) {
      // 上报失败不影响使用
    }
  }

  /// 稳定的设备标识：首次生成随机串，之后固定。上报用，无隐私内容。
  Future<String> deviceId() async {
    if (_deviceId != null) return _deviceId!;
    final p = await SharedPreferences.getInstance();
    var id = p.getString(_kDevice);
    id ??= 'dev-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}-'
        '${(DateTime.now().microsecondsSinceEpoch & 0xFFFF).toRadixString(36)}';
    await p.setString(_kDevice, id);
    _deviceId = id;
    return id;
  }

  // ============================================================
  // 纯函数（供单测直接覆盖，不做任何 IO）
  // ============================================================

  /// 语义化版本比较：a < b 返回 true。位数不同按补零对齐（0.7 < 0.7.1）。
  static bool versionLess(String a, String b) {
    final pa = a.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final pb = b.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final n = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < n; i++) {
      final x = i < pa.length ? pa[i] : 0;
      final y = i < pb.length ? pb[i] : 0;
      if (x != y) return x < y;
    }
    return false;
  }

  /// 当前运行平台对应的安装包键名
  static String _platformKey() {
    if (Platform.isAndroid) return 'android';
    if (Platform.isWindows) return 'windows';
    if (Platform.isIOS) return 'ios';
    return 'universal';
  }

  /// 从 upgradePackages 里挑当前平台的包；没有则回退 universal。
  static String? _pickPackage(Map pkgs) {
    for (final k in [_platformKey(), 'universal']) {
      final v = pkgs[k];
      if (v is String && v.trim().isNotEmpty) return v.trim();
    }
    return null;
  }

  /// 把可能的相对地址（以 / 开头）拼成基于当前服务器地址的绝对地址。
  String _resolveUrl(String raw) {
    final s = raw.trim();
    if (s.startsWith('/')) {
      final base = Config.baseUrl;
      if (base.isEmpty) return s;
      return base.replaceAll(RegExp(r'/$'), '') + s;
    }
    return s;
  }
}
