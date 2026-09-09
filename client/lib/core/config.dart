import 'dart:io';

/// 服务端地址配置 — 双地址 + 自动探测模式
///
/// 设计参考主流 IM（钉钉 / 企业微信 / Slack / Element）的体验：
/// - 内网地址（LAN）：办公网下直接连，速度快、不限速
/// - 外网地址（WAN）：出差/在家走 ZeroNews / Tailscale 域名
/// - 网络模式：auto / lan / wan 三档
///   - auto：启动时并发探测两个地址，谁先连通用谁；探测结果缓存 5 分钟
///   - lan / wan：强制用某个地址（探测被跳过；适合已知环境）
///
/// 启动时 Settings.load() 把 lan/wan/mode 全部读出来；
/// `Config.pickUrl()` 在 main() 启动或 api 调用前决定当前实际地址。
class Config {
  // ============================================================
  // 打包内置默认值（--dart-define=BASE_URL=... 可覆盖）
  // ============================================================
  static const String builtInBaseUrl = String.fromEnvironment(
    'BASE_URL',
    defaultValue: 'http://localhost:3602',
  );

  // ============================================================
  // 网络模式常量
  // ============================================================
  static const String modeAuto = 'auto';
  static const String modeLan = 'lan';
  static const String modeWan = 'wan';

  // ============================================================
  // 运行时三段地址 + 模式
  // ============================================================

  /// 内网地址（办公网下用，飞牛 IP）
  static String lanUrl = builtInBaseUrl;

  /// 外网地址（出差/在家用，ZeroNews 域名，可空）
  static String wanUrl = '';

  /// 网络模式：auto | lan | wan
  /// 默认 auto——首次启动就靠探测
  static String mode = modeAuto;

  /// 当前正在使用的地址（探测/切换后由 pickUrl() 写入）
  /// 兼容旧代码：socket.dart、api.dart 都读 baseUrl
  static String currentUrl = builtInBaseUrl;

  /// 用户是否改过（任一地址或模式与内置默认不同）
  static bool get isCustom =>
      lanUrl != builtInBaseUrl || wanUrl.isNotEmpty || mode != modeAuto;

  /// 兼容旧接口：返回当前生效地址
  static String get baseUrl => currentUrl;

  /// 兼容旧接口：返回 WS 地址
  static String get wsUrl =>
      currentUrl.replaceFirst(RegExp(r'^http'), 'ws');

  // ============================================================
  // 探测结果缓存（5 分钟内不重复探测）
  // ============================================================
  static DateTime? _lastProbeAt;
  static String? _lastProbeUrl;

  /// 是否在探测缓存有效期内（5 分钟）
  static bool _probeCacheValid() {
    if (_lastProbeAt == null || _lastProbeUrl == null) return false;
    return DateTime.now().difference(_lastProbeAt!).inMinutes < 5;
  }

  /// 标记探测结果（写到缓存）
  static void _markProbe(String url) {
    _lastProbeAt = DateTime.now();
    _lastProbeUrl = url;
    currentUrl = url;
  }

  /// 入口：根据当前 mode 决定 baseUrl
  /// - mode=lan：直接用 lanUrl
  /// - mode=wan：直接用 wanUrl（空则 fallback lan）
  /// - mode=auto（默认）：探测两者（带缓存）
  static Future<String> pickUrl({bool force = false}) async {
    // 1) 强制模式：直接选
    if (mode == modeLan && lanUrl.isNotEmpty) {
      _markProbe(lanUrl);
      return currentUrl;
    }
    if (mode == modeWan && wanUrl.isNotEmpty) {
      _markProbe(wanUrl);
      return currentUrl;
    }

    // 2) 强制模式但对应地址为空：回退到非空的那个
    if (mode == modeLan && wanUrl.isNotEmpty) {
      _markProbe(wanUrl);
      return currentUrl;
    }
    if (mode == modeWan && lanUrl.isNotEmpty) {
      _markProbe(lanUrl);
      return currentUrl;
    }

    // 3) 自动模式：用缓存 / 探测
    if (!force && _probeCacheValid()) {
      return _lastProbeUrl!;
    }

    // 4) 并发探测
    final lan = lanUrl.isNotEmpty ? lanUrl : null;
    final wan = wanUrl.isNotEmpty ? wanUrl : null;
    if (lan == null && wan == null) {
      currentUrl = builtInBaseUrl;
      return currentUrl;
    }
    if (lan != null && wan == null) {
      _markProbe(lan);
      return currentUrl;
    }
    if (wan != null && lan == null) {
      _markProbe(wan);
      return currentUrl;
    }
    // 两个都存在：并发探测，先到先用
    final winner = await _raceProbe(lan!, wan!);
    _markProbe(winner);
    return currentUrl;
  }

  /// 并发探测，返回先连通的（任一成功即可）；都不通 fallback 到 LAN
  static Future<String> _raceProbe(String a, String b) async {
    try {
      final results = await Future.wait([
        _probe(a),
        _probe(b),
      ]).timeout(const Duration(seconds: 4));
      for (final r in results) {
        if (r.ok) return r.url;
      }
      return a; // 都不通 fallback 到 LAN（用户最常用）
    } catch (_) {
      return a; // 超时 fallback 到 LAN
    }
  }

  static Future<_ProbeResult> _probe(String url) async {
    try {
      final c = HttpClient();
      c.connectionTimeout = const Duration(seconds: 2);
      try {
        final req = await c.getUrl(Uri.parse('$url/api/health'));
        req.headers.set(HttpHeaders.userAgentHeader, 'XiaozhiIM-Probe/1.0');
        final resp = await req.close().timeout(const Duration(seconds: 3));
        final ok = resp.statusCode == 200;
        // drain stream
        await resp.drain<void>();
        return ok ? _ProbeResult.ok(url) : _ProbeResult.fail(url);
      } finally {
        c.close(force: true);
      }
    } catch (_) {
      return _ProbeResult.fail(url);
    }
  }

  /// 规范化用户输入的地址：
  /// 192.168.1.9:3602 -> http://192.168.1.9:3602
  static String normalize(String input) {
    var s = input.trim();
    if (s.isEmpty) return s;
    s = s.replaceAll(RegExp(r'/+$'), '');
    if (!s.startsWith(RegExp(r'https?://', caseSensitive: false))) {
      s = 'http://$s';
    }
    return s;
  }

  /// 重置探测缓存（切网络后手动调用）
  static void invalidateProbeCache() {
    _lastProbeAt = null;
    _lastProbeUrl = null;
  }

  /// 强制重探（设置保存后调用一次）
  static Future<String> resolveNow() async {
    invalidateProbeCache();
    return pickUrl(force: true);
  }
}

class _ProbeResult {
  final String url;
  final bool ok;
  const _ProbeResult.ok(this.url) : ok = true;
  const _ProbeResult.fail(this.url) : ok = false;
}