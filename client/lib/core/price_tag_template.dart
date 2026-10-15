/// 价签**模板**：一张标签上印什么、怎么排、纸多大。
///
/// ─────────────────────────────────────────────────────────────
/// 为什么要有模板，而不是"一种价签印到底"
/// ─────────────────────────────────────────────────────────────
/// 货架上的标签从来不止一种：日常货架是「品名 + 价 + 条码」，堆头上的促销
/// 是「原价划掉 + 促销价反白放大」，生鲜称重的要带「元/kg」，会员商品要
/// 把会员价印上去。打印机的纸也只有那么宽，不同用途排版根本不一样。
///
/// 得力那套标签软件卖的就是这个：先选纸张、再拖几个元素进去、存成模板。
/// 我们把同一套形态搬过来 —— 区别只是我们的元素表是**封闭**的（8 种），
/// 因为无人值守的场景里，"让人自由发挥"的代价是打出一堆废纸。
///
/// ─────────────────────────────────────────────────────────────
/// 三条硬规矩
/// ─────────────────────────────────────────────────────────────
/// 1. **元素字段是枚举**：文本只能取商品自带的那些字段（品名/规格/售价/
///    会员价/原价/条码/日期/序号），外加一句固定话术。
///    不允许写"任意表达式" —— 一旦能写表达式，就有人写出 ${a/b}，
///    然后在某个没有会员价的商品上除零，打出一整卷废纸。
///
/// 2. **空值整行跳过**：会员价是 0、原价 <= 售价、规格为空时，那一行
///    **一个字都不印**，而不是印「会员价 ￥0.00」。
///    印一句假话出去，比不印糟糕 —— 顾客会当真。
///
/// 3. **内置模板不可删**：内置的 6 套只可"另存为"。删光模板的后果是
///    打印页直接没有可用模板，现场只能干等着。
library;

/// 元素种类。
///
/// ⚠️ 刻意**不做**"图片/Logo/矩形框"：ESC/POS 画这些要么靠 `GS v 0` 位图
///    （要下发点阵数据，一条 75mm 的图就是几 KB，蓝牙串口发一次几十秒），
///    要么靠字符拼 —— 拼出来的框在热敏纸上只会被撕边。不做好了。
enum TagElementKind {
  text,
  barcode,
  qrcode,
  line,
  ;

  static TagElementKind? parse(String? s) {
    for (final k in TagElementKind.values) {
      if (k.name == s) return k;
    }
    return null;
  }
}

/// 文本元素取哪个字段。
enum TagField {
  name, // 商品名
  spec, // 规格 / 产地
  price, // 售价（带 ￥）
  memberPrice, // 会员价
  originPrice, // 原价（促销标签上被划掉的那个）
  unit, // 计价单位（kg / 箱…）
  barcode, // 条码数字
  date, // 打印日期
  seq, // 本批次序号
  fixed, // 固定话术（如「会员专享」）
  ;

  static TagField? parse(String? s) {
    for (final f in TagField.values) {
      if (f.name == s) return f;
    }
    return null;
  }
}

/// 对齐。存字符串而不是 int，JSON 里直接看得懂。
enum TagAlign { left, center, right }

/// 标签上的一个元素。
class TagElement {
  const TagElement({
    required this.kind,
    this.field = TagField.name,
    this.fixedText = '',
    this.scaleX = 1,
    this.scaleY = 1,
    this.bold = false,
    this.reverse = false,
    this.underline = false,
    this.align = TagAlign.left,
    this.barcodeHeight = 100,
    this.hri = true,
  });

  final TagElementKind kind;

  /// [kind] 为 text 时取哪个字段。
  final TagField field;

  /// [field] 为 fixed 时印这句话（≤16 字，多了会冲出纸宽）。
  final String fixedText;

  /// 横向放大倍数（1~8）。
  final int scaleX;

  /// 纵向放大倍数（1~8）。
  final int scaleY;

  final bool bold;

  /// 反白（黑底白字）。促销价就靠它跟正价区分开。
  final bool reverse;

  /// 下划线（给原价划一道）。
  final bool underline;

  final TagAlign align;

  /// 条码高度（点）。矮条码拿扫码枪隔远一点就扫不出来。
  final int barcodeHeight;

  /// 条码下方是否额外印一行数字。
  final bool hri;

  TagElement copyWith({
    TagElementKind? kind,
    TagField? field,
    String? fixedText,
    int? scaleX,
    int? scaleY,
    bool? bold,
    bool? reverse,
    bool? underline,
    TagAlign? align,
    int? barcodeHeight,
    bool? hri,
  }) {
    return TagElement(
      kind: kind ?? this.kind,
      field: field ?? this.field,
      fixedText: fixedText ?? this.fixedText,
      scaleX: scaleX ?? this.scaleX,
      scaleY: scaleY ?? this.scaleY,
      bold: bold ?? this.bold,
      reverse: reverse ?? this.reverse,
      underline: underline ?? this.underline,
      align: align ?? this.align,
      barcodeHeight: barcodeHeight ?? this.barcodeHeight,
      hri: hri ?? this.hri,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'kind': kind.name,
        'field': field.name,
        if (fixedText.isNotEmpty) 'text': fixedText,
        if (scaleX != 1) 'sx': scaleX,
        if (scaleY != 1) 'sy': scaleY,
        if (bold) 'b': 1,
        if (reverse) 'r': 1,
        if (underline) 'u': 1,
        'a': align.name,
        if (kind == TagElementKind.barcode)
          'bh': barcodeHeight,
        if (kind == TagElementKind.barcode && !hri) 'nohri': 1,
      };

  static TagElement? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final kind = TagElementKind.parse(raw['kind']?.toString());
    if (kind == null) return null;
    final field = TagField.parse(raw['field']?.toString());
    final align = TagAlign.values.firstWhere(
      (a) => a.name == raw['a']?.toString(),
      orElse: () => TagAlign.left,
    );
    return TagElement(
      kind: kind,
      field: field ?? TagField.name,
      fixedText: (raw['text'] ?? '').toString(),
      scaleX: _int(raw['sx'], 1, 1, 8),
      scaleY: _int(raw['sy'], 1, 1, 8),
      bold: raw['b'] != null,
      reverse: raw['r'] != null,
      underline: raw['u'] != null,
      align: align,
      barcodeHeight: _int(raw['bh'], 100, 1, 255),
      hri: raw['nohri'] == null,
    );
  }

  static int _int(Object? v, int def, int lo, int hi) {
    final n = v is num ? v.toInt() : int.tryParse(v?.toString() ?? '');
    if (n == null) return def;
    if (n < lo) return lo;
    return n > hi ? hi : n;
  }
}

/// 一套价签模板。
class PriceTagTemplate {
  const PriceTagTemplate({
    required this.id,
    required this.name,
    required this.widthMm,
    required this.heightMm,
    required this.elements,
    this.builtin = false,
  });

  final String id;

  /// 模板名（管理页与打印页都显示它）。
  final String name;

  /// 纸宽（mm）。决定打印区宽度指令与预览画布比例。
  final int widthMm;

  /// 纸高（mm）。热敏机不裁纸时只影响预览比例，不影响实际指令，
  /// 但**必须记下来** —— 预览不按比例，用户就没法判断"这行会不会挤"。
  final int heightMm;

  final List<TagElement> elements;

  /// 内置模板：不可删、不可改，只能"另存为"。
  final bool builtin;

  PriceTagTemplate copyWith({
    String? id,
    String? name,
    int? widthMm,
    int? heightMm,
    List<TagElement>? elements,
    bool? builtin,
  }) {
    return PriceTagTemplate(
      id: id ?? this.id,
      name: name ?? this.name,
      widthMm: widthMm ?? this.widthMm,
      heightMm: heightMm ?? this.heightMm,
      elements: elements ?? this.elements,
      builtin: builtin ?? this.builtin,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'w': widthMm,
        'h': heightMm,
        'elements': elements.map((e) => e.toJson()).toList(),
      };

  static PriceTagTemplate? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final id = (raw['id'] ?? '').toString();
    final name = (raw['name'] ?? '').toString();
    if (id.isEmpty || name.isEmpty) return null;
    final list = raw['elements'];
    final elements = <TagElement>[];
    if (list is List) {
      for (final e in list) {
        final el = TagElement.fromJson(e);
        if (el != null) elements.add(el);
      }
    }
    if (elements.isEmpty) return null;
    return PriceTagTemplate(
      id: id,
      name: name,
      widthMm: TagElement._int(raw['w'], 50, 20, 110),
      heightMm: TagElement._int(raw['h'], 30, 15, 300),
      elements: elements,
    );
  }

  @override
  String toString() => name;
}

/* ============================================================
 * 内置模板库
 *
 * 🔴 这 6 套必须**每一个都能通过校验**（有单测钉着）：
 *    服务员在管理台/手机上点一下就能用，撞到一个不合法的模板等于
 *    "点一下就报错"，比没有模板更糟。
 * ============================================================ */

/// 常用纸宽（与 LabelSize 的预设对齐，避免两处各说一套）。
const int _w40 = 40;
const int _w50 = 50;
const int _w58 = 58;
const int _w75 = 75;

const List<PriceTagTemplate> kBuiltinTagTemplates = <PriceTagTemplate>[
  // ── 1. 标准价签：日常货架用得最多的那张 ──
  PriceTagTemplate(
    id: 'builtin_standard',
    name: '标准价签 50×30',
    widthMm: _w50,
    heightMm: 30,
    builtin: true,
    elements: <TagElement>[
      TagElement(kind: TagElementKind.text, field: TagField.name, scaleX: 2, scaleY: 2, bold: true),
      TagElement(kind: TagElementKind.text, field: TagField.spec, align: TagAlign.left),
      TagElement(kind: TagElementKind.text, field: TagField.price, scaleX: 3, scaleY: 3, bold: true, align: TagAlign.right),
      TagElement(kind: TagElementKind.barcode, align: TagAlign.center, barcodeHeight: 100),
    ],
  ),

  // ── 2. 促销价签：原价划掉 + 促销价反白放大 ──
  //    反白是促销标签的行规：黑底白字和正价（白底黑字）隔两米也分得开。
  //    只靠"字号大一点"在货架上是分辨不出来的。
  PriceTagTemplate(
    id: 'builtin_promo',
    name: '促销价签 50×30',
    widthMm: _w50,
    heightMm: 30,
    builtin: true,
    elements: <TagElement>[
      TagElement(kind: TagElementKind.text, field: TagField.name, scaleX: 2, scaleY: 2, bold: true),
      TagElement(kind: TagElementKind.text, field: TagField.originPrice, underline: true, align: TagAlign.left),
      TagElement(kind: TagElementKind.text, field: TagField.price, scaleX: 3, scaleY: 3, bold: true, reverse: true, align: TagAlign.center),
      TagElement(kind: TagElementKind.barcode, align: TagAlign.center, barcodeHeight: 100),
    ],
  ),

  // ── 3. 会员价签：售价与会员价并列 ──
  //    会员价 <=0 时整行跳过（规矩 2），不印「会员价 ￥0.00」。
  PriceTagTemplate(
    id: 'builtin_member',
    name: '会员价签 58×40',
    widthMm: _w58,
    heightMm: 40,
    builtin: true,
    elements: <TagElement>[
      TagElement(kind: TagElementKind.text, field: TagField.name, scaleX: 2, scaleY: 2, bold: true),
      TagElement(kind: TagElementKind.text, field: TagField.spec, align: TagAlign.left),
      TagElement(kind: TagElementKind.text, field: TagField.price, scaleX: 2, scaleY: 2, bold: true, align: TagAlign.right),
      TagElement(kind: TagElementKind.text, field: TagField.memberPrice, scaleX: 2, scaleY: 2, reverse: true, align: TagAlign.right),
      TagElement(kind: TagElementKind.line),
      TagElement(kind: TagElementKind.barcode, align: TagAlign.center, barcodeHeight: 100),
    ],
  ),

  // ── 4. 称重价签：生鲜/散装，价格必须带单位 ──
  //    「￥5.80」后面不跟单位，顾客会以为是 5.8 元一份，
  //    结账时发现是按公斤算 —— 这种误会最后一定是门店吃亏。
  PriceTagTemplate(
    id: 'builtin_weight',
    name: '称重价签 40×30',
    widthMm: _w40,
    heightMm: 30,
    builtin: true,
    elements: <TagElement>[
      TagElement(kind: TagElementKind.text, field: TagField.name, scaleX: 2, scaleY: 2, bold: true),
      TagElement(kind: TagElementKind.text, field: TagField.price, scaleX: 3, scaleY: 3, bold: true, align: TagAlign.center),
      TagElement(kind: TagElementKind.text, field: TagField.unit, align: TagAlign.center),
      TagElement(kind: TagElementKind.barcode, align: TagAlign.center, barcodeHeight: 80),
    ],
  ),

  // ── 5. 堆头大标签：价格占掉半张纸 ──
  //    堆头/端架离顾客有三四米，字号不够大等于没印价格。
  PriceTagTemplate(
    id: 'builtin_jumbo',
    name: '堆头大标签 75×50',
    widthMm: _w75,
    heightMm: 50,
    builtin: true,
    elements: <TagElement>[
      TagElement(kind: TagElementKind.text, field: TagField.price, scaleX: 6, scaleY: 6, bold: true, reverse: true, align: TagAlign.center),
      TagElement(kind: TagElementKind.text, field: TagField.name, scaleX: 2, scaleY: 2, bold: true),
      TagElement(kind: TagElementKind.text, field: TagField.spec, align: TagAlign.left),
      TagElement(kind: TagElementKind.barcode, align: TagAlign.center, barcodeHeight: 110),
    ],
  ),

  // ── 6. 简易小标签：便宜的小纸，一行解决 ──
  PriceTagTemplate(
    id: 'builtin_mini',
    name: '简易小标签 40×25',
    widthMm: _w40,
    heightMm: 25,
    builtin: true,
    elements: <TagElement>[
      TagElement(kind: TagElementKind.text, field: TagField.name, scaleX: 1, scaleY: 1, bold: true),
      TagElement(kind: TagElementKind.text, field: TagField.price, scaleX: 3, scaleY: 3, bold: true, align: TagAlign.right),
      TagElement(kind: TagElementKind.barcode, align: TagAlign.center, barcodeHeight: 70),
    ],
  ),
];

/// 默认模板（没有任何选择记录时用）。
const String kDefaultTemplateId = 'builtin_standard';
