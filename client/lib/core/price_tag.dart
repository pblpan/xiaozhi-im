/// 价签：数据 + 排版 + ESC/POS 指令。
///
/// ── 为什么不绑打印机型号 ─────────────────────────────────────────
/// 市面上的蓝牙价签机 / 标签机基本都是**通用 ESC/POS**（爱普生兼容指令集），
/// 把字节原样送到打印机就行，厂商 SDK 只负责"连上并写字节"。
/// 所以这里所有排版都落成通用字节，不碰任何一家专有的 SDK —— 换机器不需要改代码。
///
/// ── 中文怎么出去 ────────────────────────────────────────────────
/// ESC/POS 的中文是 **GBK 双字节**，直接送 UTF-16 字符串会打印成一团糊且不报错。
/// 所以所有要打印的文本都先过 `GbkEncode`。
///
/// ── 出口 ────────────────────────────────────────────────────────
/// 只有 `bt_printer.dart` 会真正连接并写字节。这里只管"该发什么"。
/// 没有打印机就没法打出来看，但**指令字节是可断言的**：单测直接钉住序列
/// （条码指令、对齐、放大位、切纸），谁改坏了测试立刻红。
/// 效果本身还得现场打一张才知道。
library;

import 'gbk_encode.dart';

/// 标签纸常用**宽度**（毫米）。
///
/// 长度不设：热敏头按宽度走纸，长度是物理裁的，给一堆切纸指令反而会浪费纸。
class LabelSize {
  const LabelSize(this.name, this.widthMm);

  final String name;
  final int widthMm;

  static const LabelSize mm40 = LabelSize('40mm', 40);
  static const LabelSize mm50 = LabelSize('50mm', 50);
  static const LabelSize mm58 = LabelSize('58mm', 58);
  static const LabelSize mm75 = LabelSize('75mm', 75);

  static const List<LabelSize> presets = <LabelSize>[mm40, mm50, mm58, mm75];

  /// 热敏头常见 203dpi，1mm ≈ 8 点。
  int get dots => widthMm * 8;

  @override
  String toString() => name;
}

/// 一张价签要印的东西。
class PriceTagItem {
  const PriceTagItem({
    required this.barcode,
    required this.name,
    this.spec = '',
    this.price = 0,
    this.unit = '元',
    this.copies = 1,
  });

  final String barcode;

  /// 商品名。打印机上中文占双宽，排版按"一个汉字 = 2 个西文字符"估。
  final String name;

  /// 规格 / 产地，可以为空。
  final String spec;

  /// 售价（元）。
  final double price;

  /// 计价单位（「元」「kg」「箱」…）。只影响屏幕预览，打印的一律带 ¥。
  final String unit;

  /// 打印份数（多个货架同一张价签时 > 1）。
  final int copies;

  int get totalCopies => copies < 1 ? 1 : copies;

  @override
  String toString() => '$barcode|$name|$price';
}

/// ESC/POS 指令构造 + 排版。
///
/// 只输出**通用指令**，不认识任何厂商。要加新机型先问它支不支持 ESC/POS。
class PriceTagPrinter {
  PriceTagPrinter({LabelSize? label}) : _label = label ?? LabelSize.mm58;

  final LabelSize _label;

  LabelSize get label => _label;

  final List<int> _bytes = <int>[];

  /// 已经攒下的指令字节。
  List<int> get bytes => List<int>.unmodifiable(_bytes);

  static const int _esc = 0x1B;
  static const int _gs = 0x1D;

  List<int> _take() {
    final b = List<int>.from(_bytes);
    _bytes.clear();
    return b;
  }

  /// 初始化：`ESC @` 把对齐/行距/字号全部复位。
  ///
  /// 放在一整批的最前面。―张之内不重复发 —— 发了也不坏，但会多占纸。
  List<int> init() {
    _bytes
      ..add(_esc)
      ..add(0x40);
    return _take();
  }

  /// 打印区宽度（点）。40mm≈320、58mm≈464、75mm≈600（8 点/mm）。
  ///
  /// 🔴 不设这一步，58 以上的纸**右边会有一段打不出来**（默认值只到 40mm）。
  ///    这是"面单/标签机"最常见的第一大坑。
  List<int> setWidth(int dots) {
    _bytes
      ..add(_gs)
      ..add(0x77) // GS w
      ..add(dots % 256)
      ..add((dots ~/ 256) % 256);
    return _take();
  }

  /// 行距。`n=0` 让打印机用出厂值（比硬编一个值稳）。
  List<int> setLineSpacing(int n) {
    _bytes
      ..add(_esc)
      ..add(0x44)
      ..add(n & 0xFF); // ESC d n
    return _take();
  }

  /// 对齐：0 左 / 1 中 / 2 右。
  List<int> align(int mode) {
    _bytes
      ..add(_esc)
      ..add(0x61)
      ..add(mode & 0x03); // ESC a m
    return _take();
  }

  /// 字符放大。`GS ! n` 的**低 4 位是 x、高 4 位是 y**，别弄反 ——
  /// 弄反的现场表现是"价格变瘦但没变高"，看着像打印机坏了。
  List<int> scale({int x = 1, int y = 1}) {
    final a = ((x - 1) & 0x0F) | (((y - 1) & 0x0F) << 4);
    _bytes
      ..add(_gs)
      ..add(0x21) // GS !
      ..add(a);
    return _take();
  }

  /// 换行。`ESC d 1` 一行一行给，比 `ESC d 0` 稳（0 在某些机器上不换行）。
  List<int> feed([int lines = 1]) {
    for (var i = 0; i < lines; i++) {
      _bytes
        ..add(_esc)
        ..add(0x64)
        ..add(1);
    }
    return _take();
  }

  /// 走纸到切刀位置并切纸（没有切刀的机器会忽略后半段）。
  List<int> cut() {
    _bytes
      ..add(_esc)
      ..add(0x64)
      ..add(3) // 先走纸 3 个单位，切刀才咬得到
      ..add(_gs)
      ..add(0x56)
      ..add(0x42) // GS V B：全切
      ..add(0);
    return _take();
  }

  /// 条码：`GS k m n d…NUL`。`m=73` 是 CODE128，商品条码基本都是这个。
  ///
  /// 🔴 `n` 是**全部数据字节数**，`{B` 那类控制头也算在里面 —— 只把条码数字
  ///    填进 `n` 会让条码**错位或整条打不出来**。这里不带头（数据原样送），
  ///    所以 `n` = 条码字符串的长度，别在调用处再补东西。
  List<int> barcode(String code) {
    final data = code.codeUnits;
    _bytes
      ..add(_gs)
      ..add(0x6B) // GS k
      ..add(73) // m = CODE128
      ..add(data.length & 0xFF) // n（含 B 那一头）
      ..addAll(data)
      ..add(0); // NUL 结尾
    return _take();
  }

  /// 送一段文本，按 **GBK** 编码。
  List<int> text(String s) => GbkEncode.encode(s);

  /// 印一张：商品名 → 规格 → 放大后的价格（靠右）→ 条码 → 条码数字。
  ///
  /// 🔴 放大和对齐都是**一次性状态**：每换一部分内容都要重新设一次，
  ///    不能在开头设完就不管（价格放大完不复位，后面条码也会跟着放大）。
  /// ⚠️ 参数 `[code]` 不叫 `barcode` —— 同名会把下面的 [barcode] 方法整个遮掉，
  ///    然后 `barcode(code)` 会报"expression doesn't evaluate to a function"。
  List<int> renderTag({
    required String code,
    required String name,
    required double price,
    String spec = '',
    String unit = '元',
    int priceScale = 3,
    int maxNameChars = 16,
  }) {
    final a = <int>[];
    // ⚠️ 别写成 `priceScale > 8 ? ...` —— 紧跟标识符的 `>` 会被 analyzer 当成
    //    泛型函数调用，报一句"expression doesn't evaluate to a function"。
    var px = priceScale;
    if (px < 1) px = 1;
    if (px > 8) px = 8;
    final specLine = _specLine(spec: spec, unit: unit);

    a
      ..addAll(align(0)) // 商品名靠左
      ..addAll(text(_clip(name, maxNameChars)))
      ..addAll(feed(1));
    if (specLine.isNotEmpty) {
      a
        ..addAll(text(_clip(specLine, 16)))
        ..addAll(feed(1));
    }
    a
      ..addAll(scale(x: px, y: px))
      ..addAll(align(2)) // 价格放大后必须重新设对齐，否则还是在左边
      ..addAll(text(fmtPrice(price)))
      ..addAll(feed(1))
      ..addAll(scale(x: 1, y: 1));
    a
      ..addAll(align(1)) // 条码居中
      ..addAll(barcode(code))
      ..addAll(feed(1))
      ..addAll(text(code))
      ..addAll(feed(1));
    return a;
  }

  /// 一整批。每张之间走纸一行，最后切纸。
  ///
  /// 份数在 item 上（[PriceTagItem.copies]），同一张印多份就是多印一遍，
  /// 不是在一张里重复。
  List<int> render(List<PriceTagItem> items, {String header = ''}) {
    final out = <int>[];
    out
      ..addAll(init())
      ..addAll(setWidth(_label.dots))
      ..addAll(setLineSpacing(0));
    for (final it in items) {
      final n = it.totalCopies;
      for (var c = 0; c < n; c++) {
        out
          ..addAll(renderTag(
            code: it.barcode,
            name: it.name,
            price: it.price,
            spec: it.spec,
            unit: it.unit,
          ))
          ..addAll(feed(1));
      }
    }
    out.addAll(cut());
    return out;
  }

  /// 屏幕预览用的纯文本（排版改了这里应该跟着变；测试也钉着它）。
  String preview(List<PriceTagItem> items, {String header = '', int width = 28}) {
    final buf = StringBuffer();
    if (header.isNotEmpty) buf.writeln(header);
    for (final it in items) {
      // 价格要占一行 —— 它就是纸上放大印的那一行，预览里少了它，
      // "预览看着没问题、打出来才看见价格"就成了常事。
      buf.writeln(_fit('${fmtPrice(it.price)}  ${_clip(it.name, 12)}', width));
      buf.writeln(_fit(_specLine(spec: it.spec, unit: it.unit), width));
      buf.writeln(_fit(it.barcode, width));
      buf.writeln('-' * width);
    }
    return buf.toString();
  }

  /// 规格那一行。有规格就印规格，没有就用单位顶上（称重装「kg」比什么都不印强）。
  ///
  /// 「元」不印 —— 价格本来就带 ¥，再来一个「元」是废字。
  /// ⚠️ 打印和预览共用它，两边不会各写一套然后慢慢长歪。
  static String _specLine({required String spec, required String unit}) {
    if (spec.isNotEmpty) return spec;
    if (unit.isEmpty || unit == '元') return '';
    return unit;
  }

  /// 价格格式化。
  ///
  /// 🔴 **不做"四舍五入到整数"之类的聪明事** —— 打印出来的数字跟收银台看到的
  ///    差一分钱，比丑一点糟糕得多。
  static String fmtPrice(double price) => '¥${price.toStringAsFixed(2)}';

  /// 按打印宽度截断。一个汉字算 2 个西文字符，所以上限按"字符数"给时
  /// 中文实际占的位置会更窄一点 —— 宁可少印一个字，也别让名字冲出条码区。
  static String _clip(String s, int max) {
    final t = s.trim();
    if (t.length <= max) return t;
    return t.substring(0, max).trim();
  }

  static String _fit(String s, int width) {
    if (s.length >= width) return s.substring(0, width);
    return s + ' ' * (width - s.length);
  }
}
