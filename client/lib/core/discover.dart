import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 局域网服务器发现（与服务端 src/discover.js 配对）。
///
/// 流程：往本机所有网卡的广播地址（+255.255.255.255）发探测包，
/// 收集 2 秒内的应答，按 IP 去重后返回。
///
/// 为什么按网卡广播而不是只发 255.255.255.255：
/// Windows/桌面机常见多网卡（以太网+WiFi+虚拟网卡），受限广播地址
/// 不一定走对网卡；逐网卡定向广播保证"服务器在哪张网段都能问到"。
class DiscoveredServer {
  final String url; // http://192.168.31.44:3602
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

  /// 扫描局域网。[timeout] 内收到的所有应答都算数。
  /// [port] 仅测试用（默认 3616），生产别传。
  /// 扫不到就返回空列表 —— 调用方提示手填地址，绝不抛错。
  static Future<List<DiscoveredServer>> scan({
    Duration timeout = const Duration(seconds: 2),
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
      final dg = sock!.receive();
      if (dg == null) return;
      try {
        final m = jsonDecode(utf8.decode(dg.data)) as Map;
        if (m['app'] != 'xiaozhi-im') return;
        final ip = dg.address.address;
        final port = m['httpPort'];
        if (port is! int || port <= 0 || port > 65535) return;
        found.add(DiscoveredServer(
          url: 'http://$ip:$port',
          ip: ip,
          companyName: (m['companyName'] ?? '').toString(),
          friendMode: (m['friendMode'] ?? 'normal').toString(),
          serverVersion: (m['serverVersion'] ?? '').toString(),
        ));
      } catch (_) {
        // 坏包/别家设备的应答：忽略
      }
    });

    // 组齐所有网卡的定向广播地址 + 受限广播地址
    final targets = <InternetAddress>[InternetAddress('255.255.255.255')];
    try {
      final ifs = await NetworkInterface.list();
      for (final itf in ifs) {
        for (final a in itf.addresses) {
          if (a.type != InternetAddressType.IPv4) continue;
          final mask = a.rawAddress;
          // 只对私网地址广播（169.254 链路本地广播通常没意义，跳过）
          if (mask[0] == 169 && mask[1] == 254) continue;
          final bcast = Uint8List.fromList(
              [mask[0] | 255, mask[1] | 255, mask[2] | 255, 255]);
          targets.add(InternetAddress.fromRawAddress(bcast));
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
