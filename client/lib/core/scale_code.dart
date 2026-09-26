// 电子秤码（生鲜称重码 / 店内码）的解析。
//
// ── 为什么长度不能写死 ─────────────────────────────────────
// 龙哥 2026-09-25：「各软件支持的不一样，一般在**类别属性**里定义（泰格是 5 位）」。
// 所以商品码位数是个**参数**，默认 5，管理台可改。写死 5 的后果是：
// 换一套软件（或用 4 位/6 位的门店）之后，秤码被解析成别的商品、
// 数量也跟着错，而**全程不报错** —— 扫出来还是个正常的条码样子。
//
// ── 码的构成（EAN-13 店内码，泰格那种 13 位）────────────────
//   [前缀 2 位，'20'~'29'][商品码 N 位][重量或金额 5 位][校验位 1 位]
//   总长 = N + 8　（N=5 时就是 13 位，与泰格一致）
//
// 🔴 前缀是 **2 位**不是 1 位：1+N+5+1 = N+7，N=5 时只有 12 位，
//    凑不出 EAN-13 的 13 位 —— 第一版就栽在这（CI 测试抓的）。
//    店内码的 EAN 前缀段本来就是 20~29（两位、以 2 开头）。
//
// 🔴 **不校验最后那位**。校验算法各家不同（有的是加权和 mod 10、有的没有），
//    硬校会让"别的门店的合法秤码"被判成非法 —— 而现场的表现是
//    "这个码扫不出来"，员工只会以为条码坏了。所以只解、不判对错。
//
// 🔴 认不出来时必须返回 null，**不能把原条码当成普通商品码继续用**：
//    那样会把"称了 1.25 公斤的某商品"记成"1 个条码为 2xxxx 的商品"，
//    而这条数据看上去完全正常。

/// 后 5 位数字表示的是什么。
enum ScaleCodeMode {
  /// 重量，单位是**克**（01250 = 1.25 公斤）。
  weight,

  /// 金额，单位是**分**（01250 = 12.50 元）。
  amount,
}

class ScaleCodeInfo {
  const ScaleCodeInfo({
    required this.raw,
    required this.plu,
    required this.mode,
    required this.value,
  });

  /// 原始条码（原样留着，界面上要显示"扫到的是这个码"）。
  final String raw;

  /// 解出来的**商品码**（PLU / 秤码），拿它去商档查名字。
  final String plu;

  final ScaleCodeMode mode;

  /// 后 5 位的原值（重量=克，金额=分）。
  final int value;

  /// 折算成公斤（重量码）。金额码返回 null ——
  /// 拿金额除以某个单价去"算"公斤是猜，猜出来的数看着也正常，最危险。
  double? get kg =>
      mode == ScaleCodeMode.weight ? value / 1000 : null;
}

class ScaleCode {
  ScaleCode._();

  /// 商品码位数的默认值（泰格是 5 位）。
  static const int defaultCodeLen = 5;

  static const int _digitLen = 5; // 重量/金额位
  static const int _tailLen = 1; // 校验位
  static const int _prefixLen = 2; // 店内码前缀（'20'~'29'）

  /// 总长 = 2 前缀 + N 商品码 + 5 数量 + 1 校验。
  static int totalLen(int codeLen) =>
      _prefixLen + codeLen + _digitLen + _tailLen;

  /// 像不像一个秤码（只按**形状**判断：全数字 + 长度正好 + 2 开头）。
  ///
  /// 不校验校验位：那玩意的算法各家不同，硬校会把别家门店的合法码判成非法。
  static bool looksLike(String barcode, {int codeLen = defaultCodeLen}) {
    final s = barcode.trim();
    if (s.isEmpty) return false;
    if (!RegExp(r'^\d+$').hasMatch(s)) return false;
    if (s.length != totalLen(codeLen)) return false;
    return s.startsWith('2');
  }

  /// 解析。认不出来返回 null。
  static ScaleCodeInfo? parse(
    String barcode, {
    int codeLen = defaultCodeLen,
    ScaleCodeMode mode = ScaleCodeMode.weight,
  }) {
    final s = barcode.trim();
    if (!looksLike(s, codeLen: codeLen)) return null;
    if (codeLen <= 0) return null;

    final pluStart = _prefixLen;
    final plu = s.substring(pluStart, pluStart + codeLen);
    final numStart = pluStart + codeLen;
    final v = int.tryParse(s.substring(numStart, numStart + _digitLen));
    if (v == null) return null;
    return ScaleCodeInfo(raw: s, plu: plu, mode: mode, value: v);
  }
}
