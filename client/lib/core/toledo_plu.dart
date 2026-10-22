import 'gbk_encode.dart';

/// 托利多电子秤 PLU 导入格式（RL00 标准文本格式）—— 纯排版层，零 IO 零 Flutter。
///
/// ── 规格来源（不是凭印象编的）────────────────────────────────────
/// 梅特勒-托利多《RL00 标准文本格式说明》（文本格式2）+ mt.com 中国官网
/// 条码秤 FAQ（SPCT「数据输入 → 表单化PLU → 文件 → 导入/导出 PLU」）。
///
/// 格式本体 14 个逗号分隔字段，**每条记录末尾还有一个逗号**，然后回车：
///
///   1  PLU号      0-999999        必有   秤内区分商品的编号
///   2  货号       0-9999999999999        超市统一编号（13 位）
///   3  组号       0-20 默认 0
///   4  单价       0-9999.99       必有   **以元/千克为单位**
///   5  皮重号     0-16 默认 0
///   6  成分文本号 0-150 默认 0           （本格式固定写 0：没有成分数据）
///   7  税号       0-9 默认 0
///   8  保质期     0-499 默认 0           天
///   9  推荐期     0-499 默认 0           天
///   10 固定重量   0-30.000 默认 0.000    千克（固定 0.000：不卖固定重量包装）
///   11 计价方式   0 或 1             必有   0=计重（元/千克）1=计数（元/个）
///   12 改价标志   0 或 1 默认 0           0=禁止秤上改价
///   13 打折标志   0 或 1 默认 0
///   14 商品名称   <100 字符          必有   SPCT 只接受前 14 个汉字
///
/// 缺 PLU号/单价/商品名称/计价方式任一 → SPCT 判无效记录；
/// 缺"计价方式"连计重/计数都判别不了（官网 FAQ 原话）。
///
/// 两种落法（由格式 id 决定，**不是**用户参数：选择器里"托利多 PLU"与
/// "托利多 TXT"两个入口本身就说清了文件形态，再配一个开关只会互相矛盾）：
///   · 'plu' —— 首行插魔数 `MTCN_RL00_4.1_ETH_PLU`，SPCT 表单化PLU 里
///     「文件 → 打开」直接导入（默认，最少步骤）；
///   · 'txt' —— 纯 RL00 文本，走 SPCT 的「TXT→PLU」转换向导（要手工对列）。
///
/// 🔴 编码是 **GBK（CP936）、不带 BOM**，不是 UTF-8：
///    SPCT 是传统 Windows 软件，读文本按系统 ANSI 码页（中文系统=GBK）；
///    官方推荐流程就是"Excel 另存 CSV 改扩展名"，而 Excel 在中文 Windows
///    上默认存的就是 GBK。写成 UTF-8 的表现是"导入成功但商品名全乱码"。
///    复用客户端已有的 [GbkEncode]（价签打印同源，tools/gen_gbk_table.py 生成）。
///
/// 🔴 单价口径：RL00 的单价单位是**元/千克**。国内商超的售价几乎都是
///    "斤价"（元/500g），直接导会把单价少一半 —— 顾客按 0.5 千克付钱、
///    收的是半价。所以单位带斤家族（斤/500g/500克/两）的商品自动 ×2。
class ToledoRow {
  final String barcode;
  final String name;
  final num price;
  final String unit;

  const ToledoRow({
    required this.barcode,
    required this.name,
    required this.price,
    this.unit = '',
  });
}

/// 导出参数。字段与服务端 exportfmt.js 的 TOLEDO_DEFAULTS **一一对应** ——
/// 服务端存、客户端解释，两边默认值必须逐字段一致，否则会出现
/// "服务端存了默认值、客户端按另一套默认解释"的幽灵配置。
/// 文件形态（.plu/.txt）不在这里：它由格式 id 决定，见 [ToledoPlu.build]。
class ToledoParams {
  final String pluMode; // 'seq' | 'barcode_tail'
  final int group; // 组号 0~20
  final int tare; // 皮重号 0~16
  final int tax; // 税号 0~9
  final int shelfLife; // 保质期（天）0~499
  final int recommendLife; // 推荐期（天）0~499
  final String priceMode; // 'auto' | 'weight' | 'count'
  final int allowReprice; // 改价标志 0/1
  final int allowDiscount; // 打折标志 0/1

  const ToledoParams({
    this.pluMode = 'seq',
    this.group = 0,
    this.tare = 0,
    this.tax = 0,
    this.shelfLife = 0,
    this.recommendLife = 0,
    this.priceMode = 'auto',
    this.allowReprice = 0,
    this.allowDiscount = 0,
  });

  static const ToledoParams defaults = ToledoParams();

  Map<String, dynamic> toJson() => {
        'pluMode': pluMode,
        'group': group,
        'tare': tare,
        'tax': tax,
        'shelfLife': shelfLife,
        'recommendLife': recommendLife,
        'priceMode': priceMode,
        'allowReprice': allowReprice,
        'allowDiscount': allowDiscount,
      };

  /// 从服务端/本地存储还原。**坏值一律回落默认**，不抛错：
  /// 这份参数存的是"导出习惯"，坏了一条不该让导出整个进行不下去。
  factory ToledoParams.fromJson(Map<String, dynamic>? j) {
    if (j == null) return defaults;
    int pickInt(String k, int def, int lo, int hi) {
      final v = j[k];
      if (v is int) return v.clamp(lo, hi);
      if (v is num) return v.toInt().clamp(lo, hi);
      return def;
    }

    String pickEnum(String k, String def, List<String> allowed) {
      final v = j[k];
      return (v is String && allowed.contains(v)) ? v : def;
    }

    return ToledoParams(
      pluMode: pickEnum('pluMode', 'seq', const ['seq', 'barcode_tail']),
      group: pickInt('group', 0, 0, 20),
      tare: pickInt('tare', 0, 0, 16),
      tax: pickInt('tax', 0, 0, 9),
      shelfLife: pickInt('shelfLife', 0, 0, 499),
      recommendLife: pickInt('recommendLife', 0, 0, 499),
      priceMode: pickEnum('priceMode', 'auto', const ['auto', 'weight', 'count']),
      allowReprice: pickInt('allowReprice', 0, 0, 1),
      allowDiscount: pickInt('allowDiscount', 0, 0, 1),
    );
  }
}

/// 排版结果。[bytes] 就是可直接落盘的 GBK 字节。
class ToledoBuild {
  final String text; // RL00 文本（CRLF 行尾；调试/预览用）
  final List<int> bytes; // GBK 编码后的字节（落盘用这个）
  final int rowCount; // 实际写出的记录数（跳过了无效行）
  final int missedNames; // 商品名里有几个字 GBK 编不出（导入后显示 ?）

  const ToledoBuild({
    required this.text,
    required this.bytes,
    required this.rowCount,
    required this.missedNames,
  });
}

class ToledoPlu {
  ToledoPlu._();

  /// .plu 变体的首行魔数（SPCT 靠它认文件形态）
  static const String magicLine = 'MTCN_RL00_4.1_ETH_PLU';

  /// SPCT 只接受前 14 个汉字（半角会自动转全角）
  static const int nameMaxRunes = 14;

  /// 计数类单位：这些按"个"卖（计价方式=1）。其余默认计重。
  static const List<String> _countUnits = <String>[
    '个', '袋', '盒', '瓶', '件', '包', '只', '条', '根', '支', '桶', '箱',
    '片', '块', '卷', '打', '套', '双', '枚', '颗', '粒', '碗', '杯', '壶',
    '罐', '笼', '串', '把', '听', '排', '提', '组',
  ];

  /// 斤家族：售价按 500 克报，导成 RL00 的元/千克要 ×2。
  static bool _isJinUnit(String unit) {
    final u = unit.trim().toLowerCase();
    return u == '斤' || u == '两' || u == '500g' || u == '500克' || u == '500G';
  }

  static int _byCount(String unit, String priceMode) {
    if (priceMode == 'weight') return 0;
    if (priceMode == 'count') return 1;
    final u = unit.trim();
    if (u.isEmpty) return 0; // 单位不明默认计重（秤上 PLU 绝大多数是散称）
    return _countUnits.contains(u) ? 1 : 0;
  }

  /// 单价：非负、≤9999.99、斤价 ×2 换成千克价，保留两位小数。
  static double _priceOut(num price, String unit) {
    var p = price.toDouble();
    if (!p.isFinite || p < 0) p = 0;
    if (_isJinUnit(unit)) p *= 2;
    if (p > 9999.99) p = 9999.99;
    return p;
  }

  /// PLU 号（秤内编号，1~999999）。
  /// [seqIndex] 是"第几条有效记录"（从 0 开始），seq 模式下 = 它 + 1。
  static int _pluOf(ToledoRow row, int seqIndex, String pluMode) {
    if (pluMode == 'barcode_tail') {
      final digits = row.barcode.replaceAll(RegExp(r'[^0-9]'), '');
      if (digits.length >= 6) {
        final v = int.tryParse(digits.substring(digits.length - 6)) ?? 0;
        if (v >= 1 && v <= 999999) return v;
      }
      // 条码太短/非数字/尾 6 位是 0 → 回落 seq（宁可连续编号，
      // 也不要把一堆商品压到同一个 PLU 上互相覆盖）
    }
    return seqIndex + 1;
  }

  /// 货号（超市统一编号，≤13 位）：条码原样搬；超长取后 13 位；
  /// 非数字给 0（规格允许 0，表示"无货号"）。
  static String _itemNoOf(ToledoRow row) {
    final digits = row.barcode.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return '0';
    if (digits.length > 13) return digits.substring(digits.length - 13);
    return digits;
  }

  /// 商品名称：必有字段。空名用条码兜底；逗号/换行会撕裂纯逗号分隔的
  /// 格式（RL00 没有引号转义机制）→ 换全角/空格；控制字符剔除；
  /// 超过 14 个 rune 截断（SPCT 只认前 14 个汉字）。
  static String _nameOf(ToledoRow row) {
    var n = row.name.trim();
    if (n.isEmpty) n = row.barcode.trim();
    if (n.isEmpty) return '';
    n = n
        .replaceAll(',', '，')
        .replaceAll('\r', ' ')
        .replaceAll('\n', ' ')
        .replaceAll(RegExp(r'[\u0000-\u001f\u007f]'), ' ');
    final runes = n.runes.toList();
    if (runes.length > nameMaxRunes) {
      n = String.fromCharCodes(runes.take(nameMaxRunes));
    }
    return n;
  }

  /// 排版 + GBK 编码。[rows] 为空时返回只有首行（或无内容）的空文件，
  /// 调用方应自己挡掉"没有可导出的行"。
  ///
  /// [variant] 文件形态：'plu' = 带魔数首行（SPCT 直接打开），
  /// 'txt' = 纯 RL00 文本（走 SPCT 转换向导）。由格式 id 决定，见 [ExportFormats]。
  static ToledoBuild build(List<ToledoRow> rows,
      {required String variant, ToledoParams? params}) {
    final p = params ?? ToledoParams.defaults;
    final b = StringBuffer();
    if (variant == 'plu') b.write('$magicLine\r\n');
    var count = 0;
    var missed = 0;
    for (final row in rows) {
      final name = _nameOf(row);
      // 名称是必有字段，条码也没有 → 这条记录进了 SPCT 也是无效记录，跳过
      if (name.isEmpty) continue;
      if (GbkEncode.missCount(name) > 0) missed++;
      final plu = _pluOf(row, count, p.pluMode);
      final itemNo = _itemNoOf(row);
      final price = _priceOut(row.price, row.unit);
      final byCount = _byCount(row.unit, p.priceMode);
      b.write('$plu,$itemNo,${p.group},${price.toStringAsFixed(2)},'
          '${p.tare},0,${p.tax},${p.shelfLife},${p.recommendLife},0.000,'
          '$byCount,${p.allowReprice},${p.allowDiscount},$name,\r\n');
      count++;
    }
    final text = b.toString();
    return ToledoBuild(
      text: text,
      bytes: GbkEncode.encode(text),
      rowCount: count,
      missedNames: missed,
    );
  }

  /// 导出文件名。场景名 + 单号 + 固定"托利多"字样，扩展名随 [variant]。
  static String fileName(String sceneLabel, String docNo,
      {required String variant}) {
    final ext = variant == 'plu' ? 'plu' : 'txt';
    final s = sceneLabel.trim();
    final d = docNo.trim();
    final parts = <String>[
      if (s.isNotEmpty) _safe(s),
      if (d.isNotEmpty) _safe(d),
      '托利多',
    ];
    return '${parts.join('_')}.$ext';
  }

  static String _safe(String s) => s
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}
