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
import 'price_tag_template.dart';

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
    this.memberPrice = 0,
    this.originPrice = 0,
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

  /// 会员价（元）。0 或 <=0 表示"没有会员价"，模板里对应那行整行跳过 ——
  /// 印一个「会员价 ￥0.00」出去比不印更糟，顾客会以为会员白送。
  final double memberPrice;

  /// 原价（元）。促销标签上被划掉的那个数。<= 售价时视为"没做促销"，
  /// 同样整行跳过（原价 5 块、售价 8 块的标签会当场被顾客拍下来）。
  final double originPrice;

  /// 计价单位（「元」「kg」「箱」…）。只影响屏幕预览，打印的一律带 ￥。
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

  static int _clamp(int v, int lo, int hi) => v < lo ? lo : (v > hi ? hi : v);

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
  ///
  /// 🔴🔴 指令字必须是**大写 `GS W`(1D 57)**，不是小写 `GS w`(1D 77)。
  ///    小写那个是**条码宽度**（`GS w n`，只收 1 个参数），
  ///    2026-10-16 之前这里一直发的是 1D 77 带**两个**字节：
  ///    打印机把第一个字节当条码宽度、第二个字节当普通 ASCII 打出去 ——
  ///    表现是"每张标签底部莫名其妙多印一个字符"，而纸宽其实从没设上过
  ///    （所以 58mm 纸右边那一段还是会打不出来）。顺带把 40mm 纸的
  ///    条码宽度改掉，更糟。两件事必须分开，各用各的指令。
  List<int> setWidth(int dots) {
    _bytes
      ..add(_gs)
      ..add(0x57) // GS W（大写）
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

  /// 条码宽度（`GS w n`，2~6）。
  ///
  /// 🔴 这是小写 `w`，跟上面 [setWidth] 的大写 `W` 是两条不同的指令。
  ///    窄了扫不出来，宽了 13 位 EAN 会冲出纸边，默认 3 是折中。
  List<int> barcodeWidth(int n) {
    var w = n;
    if (w < 2) w = 2;
    if (w > 6) w = 6;
    _bytes
      ..add(_gs)
      ..add(0x77)
      ..add(w);
    return _take();
  }

  /// 条码高度（`GS h n`），单位点。
  ///
  /// 出厂默认通常只有 50~80 点，贴在货架上拿扫码枪隔 20cm 扫经常读不出来。
  /// 价签条码一律给到 100 点以上。
  List<int> barcodeHeight(int dots) {
    var h = dots;
    if (h < 1) h = 1;
    if (h > 255) h = 255;
    _bytes
      ..add(_gs)
      ..add(0x68)
      ..add(h);
    return _take();
  }

  /// 条码底下那串数字印不印（`GS H n`：0 = 不印，2 = 印在下方）。
  ///
  /// 模板里条码元素自己会再印一行数字时，这个要关掉 ——
  /// 否则一个条码底下挂两串数字，看着像印重了。
  List<int> barcodeHri(bool on) {
    _bytes
      ..add(_gs)
      ..add(0x48)
      ..add(on ? 2 : 0);
    return _take();
  }

  /// 加粗 / 取消加粗（`ESC E n`）。
  ///
  /// 🔴 加粗是**状态**不是一次性开关，用完必须关掉：
  ///    开了不关，后面条码、下一张标签全会是粗的（粗条码扫不出来）。
  List<int> bold({bool on = true}) {
    _bytes
      ..add(_esc)
      ..add(0x45)
      ..add(on ? 1 : 0);
    return _take();
  }

  /// 反白（黑底白字，`GS B n`）。
  ///
  /// 促销标签的主流做法：正价是白底黑字、促销价是黑底白字，隔两米也分得出来。
  /// 只靠"字号大一点"在货架上是分辨不出来的。
  /// 同样是状态，用完必须关。
  List<int> reverse({bool on = true}) {
    _bytes
      ..add(_gs)
      ..add(0x42)
      ..add(on ? 1 : 0);
    return _take();
  }

  /// 下划线（`ESC - n`）。
  ///
  /// 用来给"原价"划一道 —— 划掉的价格表示已作废，这是促销标签的行规。
  List<int> underline({bool on = true}) {
    _bytes
      ..add(_esc)
      ..add(0x2D)
      ..add(on ? 1 : 0);
    return _take();
  }

  /// 二维码（`GS ( k` 序列）。
  ///
  /// ESC/POS 的 QR 不是一条指令，是**四步**：选模型 → 设模块大小 → 存数据 → 打印。
  /// 少任何一步都印不出来（或印出一个扫不出的方块），且不报错。
  ///
  /// ⚠️ 很老/很便宜的标签机不支持 QR，会当成乱码打一串字符出来。
  ///    所以模板里 QR 是**可选项**，默认的内置模板都不带它。
  List<int> qrcode(String data, {int moduleSize = 6}) {
    final payload = GbkEncode.encode(data);
    final a = <int>[];
    // ① 选模型：Model2（n1=50）
    a
      ..addAll(_gsK(4, 49, 65, <int>[50, 0]))
      // ② 模块大小（每个点 1~16）
      ..addAll(_gsK(3, 49, 67, <int>[_clamp(moduleSize, 1, 16)]))
      // ③ 纠错等级 M（49）—— Q 太密、老机器扫不动，L 又太脆
      ..addAll(_gsK(3, 49, 69, <int>[49]))
      // ④ 存数据
      ..addAll(_gsK(payload.length + 3, 49, 80, <int>[48, ...payload]))
      // ⑤ 打印
      ..addAll(_gsK(3, 49, 81, <int>[48]));
    return a;
  }

  /// 拼一条 `GS ( k pL pH cn fn <params>`。
  ///
  /// 🔴 pL/pH 是**整条指令的字节数**（含 cn/fn/params），低字节在前。
  ///    只把数据长度填进去会让打印机一直等后续字节，表现是"卡住不动"，
  ///    比报错难排查得多。
  List<int> _gsK(int bodyLen, int cn, int fn, List<int> params) {
    final n = bodyLen;
    return <int>[
      _gs,
      0x28, // (
      0x6B, // k
      n & 0xFF,
      (n >> 8) & 0xFF,
      cn,
      fn,
      ...params,
    ];
  }

  /// 一条横线。
  ///
  /// ESC/POS 没有画线指令 —— 得力那类软件打印出来的线，本质也是**用字符铺满一行**。
  /// 这里用 `_`（下划线字符）铺满整行宽度，视觉上就是一条线。
  /// 用 `_` 而不是 `-`：连续的下划线字符在大多数字体里是**首尾相接**的，
  /// 减号中间有断口，看着像虚线。
  List<int> line([int? widthDots]) {
    final cols = (widthDots ?? _label.dots) ~/ 12; // 12 = 一个西文字符的点宽
    return text('_' * (cols < 1 ? 1 : cols));
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

  /// 按**模板**印一整批。
  ///
  /// 与 [render] 的区别：[render] 是写死的"品名/规格/大价/条码"，
  /// 这里是"模板说什么就印什么"。新增模板不用改这个方法。
  List<int> renderWithTemplate(List<PriceTagItem> items, PriceTagTemplate tpl) {
    final out = <int>[];
    final w = tpl.widthMm * 8;
    out
      ..addAll(init())
      ..addAll(setWidth(w))
      ..addAll(setLineSpacing(0));
    var seq = 0;
    for (final it in items) {
      for (var c = 0; c < it.totalCopies; c++) {
        seq++;
        out
          ..addAll(tagBytes(tpl, it, seq: seq))
          ..addAll(feed(1));
      }
    }
    out.addAll(cut());
    return out;
  }

  /// 印一张（模板版）。元素里取到空内容的会**整行跳过**。
  List<int> tagBytes(PriceTagTemplate tpl, PriceTagItem item,
      {int seq = 1, String dateText = ''}) {
    final a = <int>[];
    final w = tpl.widthMm * 8;
    for (final e in tpl.elements) {
      a.addAll(_elementBytes(e, item,
          widthDots: w, seq: seq, dateText: dateText));
    }
    return a;
  }

  List<int> _elementBytes(TagElement e, PriceTagItem item,
      {required int widthDots, required int seq, required String dateText}) {
    if (e.kind == TagElementKind.line) {
      return <int>[...align(0), ...line(widthDots), ...feed(1)];
    }

    if (e.kind == TagElementKind.barcode) {
      if (item.barcode.isEmpty) return const <int>[];
      return <int>[
        ...align(_alignCode(e.align)),
        ...barcodeHeight(e.barcodeHeight),
        ...barcodeHri(e.hri),
        ...barcode(item.barcode),
        ...feed(1),
        // 🔴 复位：条码高度/HRI 是状态，不复位的话下一张的条码会跟着变高
        ...barcodeHeight(80),
        ...barcodeHri(false),
      ];
    }

    if (e.kind == TagElementKind.qrcode) {
      if (item.barcode.isEmpty) return const <int>[];
      return <int>[...align(_alignCode(e.align)), ...qrcode(item.barcode), ...feed(1)];
    }

    // ── text ──
    final s = tagFieldText(e, item,
        scaleX: e.scaleX, widthDots: widthDots, seq: seq, dateText: dateText);
    if (s.isEmpty) return const <int>[]; // 空值整行跳过
    final a = <int>[];
    a
      ..addAll(align(_alignCode(e.align)))
      ..addAll(scale(x: e.scaleX, y: e.scaleY));
    if (e.bold) a.addAll(bold(on: true));
    if (e.reverse) a.addAll(reverse(on: true));
    if (e.underline) a.addAll(underline(on: true));
    a
      ..addAll(text(s))
      ..addAll(feed(1));
    // 🔴 加粗/反白/下划线/放大全是状态，用完一律关掉 ——
    //    粗条码扫不出来，反白跑到下一行会把整行涂黑。
    if (e.underline) a.addAll(underline(on: false));
    if (e.reverse) a.addAll(reverse(on: false));
    if (e.bold) a.addAll(bold(on: false));
    a.addAll(scale(x: 1, y: 1));
    return a;
  }

  static int _alignCode(TagAlign a) {
    switch (a) {
      case TagAlign.left:
        return 0;
      case TagAlign.center:
        return 1;
      case TagAlign.right:
        return 2;
    }
  }

  /// 某个文本元素**此刻**该印什么。返回空串 = 这一行整个不印。
  ///
  /// 🔴 "取到空就不印"是硬性规矩，不是省事：
  ///    印一句「会员价 ￥0.00」出去，顾客会当真去要那个价 ——
  ///    印一句假话，比不印糟糕得多。
  static String tagFieldText(
    TagElement e,
    PriceTagItem item, {
    required int scaleX,
    required int widthDots,
    int seq = 0,
    String dateText = '',
  }) {
    switch (e.field) {
      case TagField.name:
        return clipToWidth(item.name, scaleX, widthDots);
      case TagField.spec:
        return clipToWidth(item.spec, scaleX, widthDots);
      case TagField.price:
        return fmtPrice(item.price);
      case TagField.memberPrice:
        // 会员价 <= 0 视为"这个商品没有会员价"，整行跳过
        if (item.memberPrice <= 0) return '';
        return '会员 ${fmtPrice(item.memberPrice)}';
      case TagField.originPrice:
        // 原价不高于售价 = 没做促销，划掉一个更低的原价是骗人
        if (item.originPrice <= item.price) return '';
        return '原价 ${fmtPrice(item.originPrice)}';
      case TagField.unit:
        // 「元」不印：价格本身就带 ￥
        return (item.unit.isEmpty || item.unit == '元') ? '' : item.unit;
      case TagField.barcode:
        return item.barcode;
      case TagField.date:
        return dateText;
      case TagField.seq:
        return 'No.$seq';
      case TagField.fixed:
        return clipToWidth(e.fixedText, scaleX, widthDots);
    }
  }

  /// 按"打印出来占多少点"截断。
  ///
  /// 🔴 上限必须**跟着放大倍数走**：2 倍字号的一行只能放一半字。
  ///    原来固定写死 16 的后果是 —— 小字时右边空一大截，大字时直接冲出纸边，
  ///    而冲出去的部分在热敏纸上不是"看不见"，是**挤成一团糊**。
  ///    模板体系里放大倍数是用户自己调的，写死上限必然出事。
  static String clipToWidth(String s, int scaleX, int widthDots) {
    final t = s.trim();
    final sc = scaleX < 1 ? 1 : scaleX;
    final cap = widthDots ~/ (12 * sc); // 一行能放几个西文字符
    if (cap < 1 || t.isEmpty) return '';
    var used = 0;
    final buf = StringBuffer();
    for (final r in t.runes) {
      final w = _runeWidth(r);
      if (used + w > cap) break;
      buf.write(String.fromCharCode(r));
      used += w;
    }
    return buf.toString().trim();
  }

  /// 一个字符占几个西文宽。中日韩全角一律按 2 算（这是热敏打印机的字形宽度约定）。
  static int _runeWidth(int r) => r > 0x2E7F ? 2 : 1;

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
  /// 「元」不印 —— 价格本来就带 ￥，再来一个「元」是废字。
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
  ///
  /// 🔴 用**全角** `￥`(U+FFE5) 不用半角 `¥`(U+00A5)：GBK 码表里只有全角那个
  ///    （0xA3A4），半角的编不出来会静默变 `?` —— CI 第一次跑价签测试就
  ///    抓到过"价格印成 ？12.90"。
  static String fmtPrice(double price) => '￥${price.toStringAsFixed(2)}';

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
