import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import 'config.dart';
import 'settings.dart';

/// 应用版本号。发版时与 pubspec.yaml（version: X.Y.Z+N）、
/// android/local.properties 三处一起改 —— 别只改一处。
const String kAppVersion = '0.8.0';

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

  bool featureOn(String name, {bool def = true}) {
    final f = payload['features'];
    if (f is Map && f[name] is bool) return f[name] as bool;
    return def;
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

      // ---- ① 服务器地址候选 ----
      final addrs = _stringList(pl['serverAddresses']);
      if (addrs.isNotEmpty && !(await Settings.hasUserServers())) {
        // 用户从没改过地址 → 跟随服务端下发；用户自己配过的优先，绝不覆盖
        final nextLan = addrs.first;
        final nextWan = addrs.length > 1 ? addrs[1] : addrs.first;
        if (nextLan != Config.lanUrl || nextWan != Config.wanUrl) {
          Config.lanUrl = nextLan;
          Config.wanUrl = nextWan;
          Config.invalidateProbeCache(); // 下次重连/手动切换时用新地址，不打断当前连接
        }
      }

      // ---- ② 功能开关 / 公告 / 维护：payload 原样保留，消费方按需读 ----
      // （features 非法的键会在 featureOn() 里走默认值，不需要在这里清洗）

      // ---- ③ 版本策略 ----
      final minVer = pl['minClientVersion'];
      if (minVer is String && minVer.isNotEmpty && versionLess(kAppVersion, minVer)) {
        upgradeHint.value = '当前版本 $kAppVersion 过低，请升级到 $minVer 或以上';
      } else {
        upgradeHint.value = null;
      }

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

  /// 提取字符串列表：非字符串元素丢弃
  static List<String> _stringList(dynamic v) {
    if (v is! List) return const [];
    return v.whereType<String>().where((s) => s.trim().isNotEmpty).toList();
  }

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
}
