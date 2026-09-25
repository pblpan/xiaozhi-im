import 'gbk_table.dart';

/// GBK **编码**（Unicode → 字节），纯 Dart、零依赖。
///
/// ── 为什么要有它 ────────────────────────────────────────────────
/// 打印机只认字节。ESC/POS 机的中文是 **GBK 双字节**，直接把 Flutter 的
/// UTF-16 字符串写过去，商品名会变成一串不可打印的控制字节 —— 打出来是
/// 白纸或者糊的，而且**不报错**。所以凡是要往打印机送中文的地方都得先过一遍它。
///
/// ── 为什么不找现成包 ────────────────────────────────────────────
/// pub 上那几个 GBK 包（gbk_codec / fast_gbk）都停在 2021 年，environment
/// 写的是 `sdk: >=2.x <3.0.0`，**在 Dart 3 上根本装不上**。
/// 复用 `gbk_table.dart` 这张解码表反着查即可，不额外占体积。
///
/// ⚠️ 反查表是**首次用到时才建**（约 2 万条），启动时不做无谓的工作。
class GbkEncode {
  GbkEncode._();

  static Map<int, int>? _byChar;

  /// 反查表：字符的码元 → GBK 双字节码（高字节 << 8 | 低字节）。
  ///
  /// 由 `gbk_table.dart` 翻转而来，所以**两个 App 的码表同源、结果必然一致**。
  static Map<int, int> get table {
    final built = _byChar;
    if (built != null) return built;
    final m = <int, int>{};
    for (var i = 0; i < kGbkTable.length; i++) {
      final u = kGbkTable.codeUnitAt(i);
      if (u == 0) continue; // U+0000 = 码表里没分配的槽位，不是真字符
      if (!m.containsKey(u)) m[u] = i; // 早分配的槽位在前，保留即可
    }
    _byChar = m;
    return m;
  }

  /// 一个字符能不能编成 GBK。
  static bool canEncode(String s) {
    if (s.isEmpty) return true;
    final t = table;
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      if (c < 0x80) continue;
      if (!t.containsKey(c)) return false;
    }
    return true;
  }

  /// 编码成 GBK 字节。
  ///
  /// ⚠️ **编不了的字符不会静默丢**：换成 `?`（0x3F）。
  ///    宁可打出一个问号让人看见，也不要吐出一段"打印机不认但也不报错"的字节 ——
  ///    那种问题的现场表现是"打了半张纸全是白的"。
  static List<int> encode(String s) {
    final t = table;
    final out = <int>[];
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      if (c < 0x80) {
        out.add(c);
        continue;
      }
      final code = t[c];
      if (code == null) {
        out.add(0x3F);
        continue;
      }
      out.add(code >> 8);
      out.add(code & 0xFF);
    }
    return out;
  }

  /// 这段里有几个字符编不进 GBK（会被打成 `?`）。
  ///
  /// 打印前用它决定要不要提醒：商品名里混进一个生僻字，整张标签就废了，
  /// 与其打出去才发现，不如在预览里先说清楚。
  static int missCount(String s) {
    final t = table;
    var n = 0;
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      if (c >= 0x80 && !t.containsKey(c)) n++;
    }
    return n;
  }
}
