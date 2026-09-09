import 'config.dart';

/// 判断当前服务端地址是否属于内网（局域网）。
/// 用途：内网带宽足 → 图片原图直传；外网/公网 → 先压缩再传，省流量省时间。
class Net {
  static bool get isLan {
    final host = Uri.tryParse(Config.baseUrl)?.host.toLowerCase() ?? '';
    if (host.isEmpty) return true;

    // 本机 / 本机域名
    if (host == 'localhost' || host == '127.0.0.1' || host == '::1') return true;
    if (host.endsWith('.local') || host.endsWith('.lan') || host.endsWith('.home.arpa')) return true;

    final parts = host.split('.');
    if (parts.length != 4) return false; // 域名（除 .local 等）按外网处理

    final a = int.tryParse(parts[0]);
    final b = int.tryParse(parts[1]);
    if (a == null || b == null) return false;

    if (a == 10) return true; // 10.0.0.0/8
    if (a == 192 && b == 168) return true; // 192.168.0.0/16（飞牛 NAS 常用）
    if (a == 172 && b >= 16 && b <= 31) return true; // 172.16.0.0/12
    if (a == 169 && b == 254) return true; // link-local
    if (a == 100 && b >= 64 && b <= 127) return true; // CGNAT / Tailscale

    return false; // 公网 IP
  }
}
