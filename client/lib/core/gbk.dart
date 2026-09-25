import 'dart:convert';

import 'gbk_table.dart';

/// GBK 解码（纯 Dart，自带码表）。
///
/// ── 为什么需要它 ──────────────────────────────────────────────
/// 商档是**导入 CSV** 的，而国内 Windows 上的 Excel / WPS / 融通 BMS /
/// 泰格 POS 导出的 CSV **默认就是 GBK**。员工按默认存出来，传到手机上，
/// 用 UTF-8 解出来就是一整屏"锟斤拷"—— 而且**不报错**，界面上看着像
/// "导入成功了，只是商品名是乱码"，比直接失败更难发现。
///
/// 所以导入时先按 UTF-8 解，解不动再退回 GBK（见 [decodeSmart]）。
/// 码表是构建前生成的，见 `tools/gen_gbk_table.py`。
class Gbk {
  Gbk._();

  /// 这个字节能不能作为 GBK 双字节码的首字节。
  static bool isLead(int b) => b >= 0x81 && b <= 0xFE;

  /// 这个字节能不能作为 GBK 双字节码的尾字节。
  /// ⚠️ 0x7F **不是**有效尾字节（GBK 规范里那一段是空的），
  ///    把它算进去会让整张表的下标错位一格、后面全解错。
  static bool isTrail(int b) =>
      (b >= 0x40 && b <= 0x7E) || (b >= 0x80 && b <= 0xFE);

  static int _trailIndex(int trail) =>
      trail <= 0x7E ? trail - 0x40 : trail - 0x80 + 63;

  /// 把一个 GBK 双字节码解成字符；不在码表里返回 null。
  static String? charAt(int lead, int trail) {
    if (!isLead(lead) || !isTrail(trail)) return null;
    final i = (lead - 0x81) * kGbkTrailCount + _trailIndex(trail);
    if (i < 0 || i >= kGbkTable.length) return null;
    final u = kGbkTable.codeUnitAt(i);
    // 码表里未分配的槽位是 U+0000。真实 GBK 里不存在 U+0000 这个字符，
    // 所以拿它当"没这个码"的哨兵是安全的。
    if (u == 0) return null;
    return String.fromCharCode(u);
  }

  /// 按 GBK 解一段字节。
  ///
  /// 解不出来的字节（孤立尾字节、未分配的码位）换成 U+FFFD（�）——
  /// 这是各编码库通用的做法，界面上能一眼看出"这一段坏了"，
  /// 而不是静默丢掉几个字。
  static String decode(List<int> bytes) {
    final out = StringBuffer();
    var i = 0;
    final n = bytes.length;
    while (i < n) {
      final b = bytes[i];
      if (b < 0x80) {
        out.writeCharCode(b);
        i++;
        continue;
      }
      if (i + 1 < n) {
        final c = charAt(b, bytes[i + 1]);
        if (c != null) {
          out.write(c);
          i += 2;
          continue;
        }
      }
      // 走到这里 = 这个字节没法解释：孤立尾字节，或码表里没这一对。
      // 只吐一个替换字符、前进一格 —— 不前进会死循环。
      out.writeCharCode(0xFFFD);
      i++;
    }
    return out.toString();
  }

  /// 这段字节是不是**合法 UTF-8**（用来决定要不要退到 GBK）。
  ///
  /// 为什么不能"先解再说"：Dart 的 UTF-8 解码器遇到非法字节要么抛
  /// （`allowMalformed: false`）、要么把非法段换成 U+FFFD 后继续
  /// （`allowMalformed: true`）。后者会给出**一段半通不通的字符串** ——
  /// 数字列是对的、中文列是问号，看起来像"文件坏了"，比明确报错更难查。
  static bool isUtf8(List<int> bytes) {
    try {
      const utf8 = Utf8Decoder();
      utf8.convert(bytes);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 商档 CSV 的解码入口：先 UTF-8，不行就 GBK。
  ///
  /// 顺序**不能反**：GBK 几乎能把任意字节流解出"字符"来（未分配的槽位
  /// 才解不出），拿它去解一份真正的 UTF-8 文件会得到一段能显示但全错的
  /// 中文 —— 那是最坏的一类结果，因为界面上根本看不出来。
  static String decodeSmart(List<int> bytes) {
    if (isUtf8(bytes)) return const Utf8Decoder().convert(bytes);
    return decode(bytes);
  }
}
