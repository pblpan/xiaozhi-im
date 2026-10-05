import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 局域网服务器发现（与服务端 src/discover.js 配对）。
///
/// 两段式扫描：
/// ① 广播：往本机所有网卡的广播地址（+255.255.255.255）发探测包；
/// ② 单播兜底：广播 ~1 秒没应答 → 对本机每个网段的 .1~.254 逐个单播探测。
///
/// 为什么需要第②段：服务器跑在 Docker bridge 容器里时，docker-proxy
/// 只转发单播 —— 广播包根本进不了容器（2026-10-05 实测：单播有应答、
/// 广播无应答）。单播逐个问虽然包多，但 UDP sendto 不阻塞，254 个地址
/// 瞬间发完，不在线的地址只是包被丢，无成本。
///
/// 为什么按网卡定向广播而不是只发 255.255.255.255：
/// Windows/桌面机常见多网卡（以太网+WiFi+虚拟网卡），受限广播地址
/// 不一定走对网卡；逐网卡定向广播保证"服务器在哪张网段都能问到"。
class DiscoveredServer {
  final String url; // 例如 http://192.168.1.100:3602（由局域网发现得出）
  final String ip;
  final String companyName;
  final String friendMode;
  final String serverVersion;

  const DiscoveredServer({
    required this.url,
    required this.ip,
    required this.companyName,
    required this.friendMode,
    required this.serverVersion,
  });

  @override
  bool operator ==(Object other) => other is DiscoveredServer && other.url == url;
  @override
  int get hashCode => url.hashCode;
}

class LanDiscover {
  static const probe = 'XIAOZHI_DISCOVER_V1';
  static const port = 3616;

  /// 扫描局域网。[timeout] 为总时长（含广播等待 + 单播兜底）。
  /// [port] 仅测试用（默认 3616），生产别传。
  /// 扫不到就返回空列表 —— 调用方提示手填地址，绝不抛错。
  static Future<List<DiscoveredServer>> scan({
    Duration timeout = const Duration(seconds: 4),
    int port = port,
  }) async {
    RawDatagramSocket? sock;
    try {
      sock = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0)
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      return const []; // 本机没有可用 UDP栈（极少见），放弃
    }

    final found = <DiscoveredServer>{};
    final completer = Completer<void>();

    sock.broadcastEnabled = true;
    final sub = sock.listen((ev) {
      if (ev != RawSocketEvent.read) return;
      final s = sock;
      if (s == null) return;
      Datagram? dg;
      try {
        dg = s.receive();
      } catch (_) {
        return; // Windows 上不在线地址的 ICMP 不可达可能在这里冒出来，忽略
      }
      if (dg == null) return;
      try {
        final m = jsonDecode(utf8.decode(dg.data)) as Map;
        if (m['app'] != 'xiaozhi-im') return;
        final ip = dg.address.address;
        final httpPort = m['httpPort'];
        if (httpPort is! int || httpPort <= 0 || httpPort > 65535) return;
        found.add(DiscoveredServer(
          url: 'http://$ip:$httpPort',
          ip: ip,
          companyName: (m['companyName'] ?? '').toString(),
          friendMode: (m['friendMode'] ?? 'normal').toString(),
          serverVersion: (m['serverVersion'] ?? '').toString(),
        ));
      } catch (_) {
        // 坏包/别家设备的应答：忽略
      }
    });

    // 组齐所有网卡的定向广播地址（/24 近似 x.x.x.255）+ 受限广播地址
    final targets = <InternetAddress>[InternetAddress('255.255.255.255')];
    final subnets = <String>{}; // /24 网段前缀，如 '192.168.31'（单播兜底用）
    try {
      final ifs = await NetworkInterface.list();
      for (final itf in ifs) {
        for (final a in itf.addresses) {
          if (a.type != InternetAddressType.IPv4) continue;
          final o = a.rawAddress;
          // 只对私网地址扫描（169.254 链路本地、127 回环没意义，跳过）
          final isPrivate = (o[0] == 10) ||
              (o[0] == 192 && o[1] == 168) ||
              (o[0] == 172 && o[1] >= 16 && o[1] <= 31);
          if (!isPrivate) continue;
          final bcast = Uint8List.fromList([o[0], o[1], o[2], 255]);
          targets.add(InternetAddress.fromRawAddress(bcast));
          subnets.add('${o[0]}.${o[1]}.${o[2]}');
        }
      }
    } catch (_) {
      // 网卡列表拿不到就只靠 255.255.255.255
    }

    final payload = utf8.encode(probe);
    for (final t in targets) {
      try {
        sock.send(payload, t, port);
      } catch (_) {
        // 个别网卡广播失败不影响其他网卡
      }
    }

    // 单播兜底：广播发出 1 秒后仍无应答 → 对每个网段 .1~.254 逐个单播问。
    // docker bridge 的 docker-proxy 只转发单播，这一步才是容器部署的真正通路。
    Timer(const Duration(seconds: 1), () {
      if (found.isNotEmpty) return; // 广播已经问到了，不折腾
      for (final seg in subnets) {
        for (var i = 1; i <= 254; i++) {
          try {
            sock!.send(payload, InternetAddress('$seg.$i'), port);
          } catch (_) {
            // 单个地址发送失败（无路由/权限）不影响其他
          }
        }
      }
    });

    // 收满 timeout 就收工
    Timer(timeout, () {
      if (!completer.isCompleted) completer.complete();
    });
    await completer.future;

    sub.cancel();
    try {
      sock.close();
    } catch (_) {/* ignore */}
    return found.toList();
  }
}
