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
/// 启动时 [SessionManager.load] 把激活档案的 lan/wan/mode 镜像进来；
/// `Config.pickUrl()` 在 main() 启动或 api 调用前决定当前实际地址。
class Config {
  // ============================================================
  // 打包内置默认值（--dart-define=BASE_URL=... 可覆盖）
  //
  // 🔴 故意留空 —— 这里**不许**再写任何生产地址（2026-09-16 客户端加固）。
  //    以前写死了内网 IP 和外网零讯域名，三个问题：
  //      1) 这是通用产品：客户拿去要连的是**他自己的**服务器，
  //         写死我们的地址 = 装完连不上，还顺手把服务器地址散播出去；
  //      2) 换个部署（换 IP / 换域名 / 换客户）就得重新出包；
  //      3) 地址信息随安装包发给所有人，等于把内部网络结构公开。
  //    三条替代路径（都已在包内）：
  //      · 首次启动自动做局域网发现（UDP 广播，见 core/discover.dart）
  //      · 用户在「服务器设置」里手填
  //      · 管理员在管理台「客户端配置」下发候选地址（core/remote_config.dart）
  //    确实需要预置地址的定制包，用 --dart-define=BASE_URL=xxx 在构建时注入，
  //    不要改回这里的字面量。
  // ============================================================
  static const String builtInBaseUrl = String.fromEnvironment(
    'BASE_URL',
    defaultValue: '',
  );

  /// 内置外网地址（ZeroNews 域名映射）——同样留空，理由同上
  /// --dart-define=WAN_URL=... 可覆盖
  static const String builtInWanUrl = String.fromEnvironment(
    'WAN_URL',
    defaultValue: '',
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

  /// 外网地址（出差/在家用，ZeroNews 域名）
  static String wanUrl = builtInWanUrl;

  /// 网络模式：auto | lan | wan
  /// 默认 auto——首次启动就靠探测
  static String mode = modeAuto;

  /// 当前正在使用的地址（探测/切换后由 pickUrl() 写入）
  /// 兼容旧代码：socket.dart、api.dart 都读 baseUrl
  static String currentUrl = builtInBaseUrl;

  /// 服务端下发的候选地址（带类型）。非空时 auto 模式全量并发探测选可达者。
  /// 空 = 回退到 lanUrl/wanUrl 的旧逻辑（兼容老服务端 / 老配置）。
  static List<ServerCandidate> serverCandidates = const [];

  /// 是否使用服务端下发的候选地址
  static bool get hasCandidates => serverCandidates.isNotEmpty;

  /// 地址类型白名单（需求3：IPv4/IPv6 + 内网/外网/其他）
  static const List<String> addrTypes = ['lan', 'wan', 'ipv4', 'ipv6', 'other'];

  /// 用户是否改过（任一地址或模式与内置默认不同）
  static bool get isCustom =>
      lanUrl != builtInBaseUrl ||
      wanUrl != builtInWanUrl ||
      mode != modeAuto;

  /// 兼容旧接口：返回当前生效地址
  static String get baseUrl => currentUrl;

  /// 是否已经知道该连哪台服务器。
  /// 为 false 时上层要引导用户去「服务器设置」（新装 + 局域网没扫到 的唯一态）。
  static bool get configured => currentUrl.isNotEmpty;

  /// 兼容旧接口：返回 WS 地址
  static String get wsUrl =>
      currentUrl.replaceFirst(RegExp(r'^http'), 'ws');

  /// 由 http(s) 地址推出对应的 ws(s) 地址（用于任意档案，不依赖全局）。
  static String wsFrom(String url) =>
      url.replaceFirst(RegExp(r'^http'), 'ws');

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

    // 4) 待探测地址列表：
    //    · 优先用服务端下发的全量候选（含 IPv4/IPv6，按优先级排序）；
    //    · 否则回退到内置的 lan/wan 两条（兼容老服务端 / 老配置）。
    final List<String> probeList;
    if (hasCandidates) {
      probeList = serverCandidates.map((c) => c.url).toList();
    } else {
      probeList = [
        if (lanUrl.isNotEmpty) lanUrl,
        if (wanUrl.isNotEmpty) wanUrl,
      ];
    }
    if (probeList.isEmpty) {
      // 一个地址都没有（新装且局域网也没扫到）→ 状态就是"未配置"。
      // ⚠️ 这里**不做任何 fallback**：宁可让上层显示"去设置服务器"，
      //    也不要悄悄连一个写死的地址（加固前这里会 fallback 到内置生产 IP）。
      currentUrl = '';
      return currentUrl;
    }
    if (probeList.length == 1) {
      _markProbe(normalize(probeList.first));
      return currentUrl;
    }
    // 多个候选：并发探测，先到先用；都不通回退到优先级最高的那条
    final winner = await _raceProbeMany(probeList);
    _markProbe(winner);
    return currentUrl;
  }

  /// 给定一组 lan/wan/mode，**不触碰全局状态**地算出该用哪个地址。
  ///
  /// 抽出这一层是为了让多企业后台连接（[BackgroundLinkService]）能独立探测
  /// 每个档案的地址，而不污染全局 `currentUrl`（那是激活企业的）。
  static Future<String> pickFor(String lan, String wan, String mode) async {
    final L = lan.trim().isEmpty ? null : normalize(lan);
    final W = wan.trim().isEmpty ? null : normalize(wan);
    if (mode == modeLan && L != null) return L;
    if (mode == modeWan && W != null) return W;
    if (mode == modeLan && W != null) return W; // 强制内网但没有内网 → 退外网
    if (mode == modeWan && L != null) return L; // 强制外网但没有外网 → 退内网
    if (L == null && W == null) return '';
    if (L != null && W == null) return L;
    if (W != null && L == null) return W;
    return _raceProbe(L!, W!); // 自动：并发探测，先到先用
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

  /// 并发探测多个候选地址，返回先连通的；都不通 fallback 到第一个（按优先级）。
  static Future<String> _raceProbeMany(List<String> urls) async {
    final norm = urls.map((u) => normalize(u)).toList();
    try {
      final results = await Future.wait(norm.map((u) => _probe(u)))
          .timeout(const Duration(seconds: 4));
      for (final r in results) {
        if (r.ok) return r.url;
      }
      return norm.first; // 都不通：回退到优先级最高的那条
    } catch (_) {
      return norm.first;
    }
  }

  /// 把服务端下发的 serverAddresses（字符串 或 {url,type}）解析成候选列表。
  /// 非法元素丢弃；字符串按格式猜类型（IPv6 / 内网 / 其他）。
  static List<ServerCandidate> parseCandidates(List<dynamic> raw) {
    final out = <ServerCandidate>[];
    for (final e in raw) {
      if (e is String && e.trim().isNotEmpty) {
        out.add(ServerCandidate(normalize(e), _guessType(e)));
      } else if (e is Map && e['url'] is String && (e['url'] as String).trim().isNotEmpty) {
        final url = normalize(e['url'] as String);
        final t = e['type'] is String ? e['type'] as String : 'other';
        out.add(ServerCandidate(url, addrTypes.contains(t) ? t : 'other'));
      }
    }
    return out;
  }

  static String _guessType(String url) {
    final u = url.trim();
    if (u.contains('[') && u.contains(']')) return 'ipv6'; // IPv6 字面量 [host]:port
    if (_privateIpRe.hasMatch(u)) return 'lan';
    return 'other';
  }

  static final RegExp _privateIpRe = RegExp(
    r'https?://(localhost|127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.|169\.254\.)',
    caseSensitive: false,
  );

  /// 单独探测一个地址是否可达（**不污染全局** `currentUrl`）。
  /// 供企业切换器显示"两个服务器地址都在链接状态"——每个档案的内网/外网各探一次。
  static Future<bool> isReachable(String url) async {
    final u = normalize(url);
    if (u.isEmpty) return false;
    return (await _probe(u)).ok;
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

/// 服务器候选地址（需求3：带类型，支持 IPv4/IPv6 区分探测）
class ServerCandidate {
  final String url;
  final String type; // lan | wan | ipv4 | ipv6 | other
  const ServerCandidate(this.url, this.type);
}