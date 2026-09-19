import 'package:sqflite/sqflite.dart';

import 'csv_fmt.dart';
import 'gbk.dart';
import 'local_db.dart';

/// 商品档案（商档）的本地仓库：**导入一份 CSV，落进本地 `stock_master` 表**。
///
/// ── 为什么商档必须是"本地底表" ────────────────────────────────
/// 扫码发生在货架之间，那里的网络不归我们管。员工扫一个条码，
/// 手机必须**当场**回答"这是什么、系统账面多少" —— 这两件事都查不了服务端。
/// 所以商档要先整份落到本地 SQLite（见 core/local_db.dart 的 stock_master），
/// 断网时照样能盘。
///
/// ── 这一版和 IM 客户端里那份的关键差别 ────────────────────────
/// 客户端那份是从泰格经服务端转发通道拉下来的（`ImApi().hookCall`）。
/// 独立扫码枪**没有服务端**：不登录、不联网、不认 IP。
/// 所以商档改成"导一份 CSV 进来"—— 员工装完 App 就能用，
/// 不用等我们把服务端部署好（那正是客户端那边卡住验收的地方）。
///
/// 落库语义不变：**整份对齐**（同条码覆盖、本次没有的旧记录清掉）。
class StockMasterRepo {
  /// 区分"这份数据是谁给的"。以后若接第二个来源（比如服务端同步），
  /// 靠它隔离，互不覆盖。
  static const String sourceTag = 'csv';

  /// 把整份商档写进本地表。返回写入条数。
  ///
  /// [purgeMissing] = 真时，会把**同一来源**下不在本次清单里的旧记录删掉
  /// （商品下架了，本地还留着它的账面数，扫码时会凭空多出一行）。
  ///
  /// 🔴 但 `items` 为空时**一律不清理**：一次空文件/选错文件，
  /// 不能把整张底表清空 —— 宁可留旧数据，也不能让员工扫什么都是"未知商品"。
  static Future<int> upsertAll(
    Database db,
    List<Map<String, dynamic>> items, {
    String source = sourceTag,
    bool purgeMissing = true,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;

    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final it in items) {
        batch.insert(
          'stock_master',
          <String, dynamic>{
            ...it,
            'source': source,
            'updated_at': now,
          },
          // 同 barcode 覆盖：商档是"全量对齐"语义，不是追加。
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }

      if (purgeMissing && items.isNotEmpty) {
        final keep = items.map((e) => e['barcode'].toString()).toList();
        final placeholders = List<String>.filled(keep.length, '?').join(',');
        batch.delete(
          'stock_master',
          where: 'source = ? AND barcode NOT IN ($placeholders)',
          whereArgs: <Object?>[source, ...keep],
        );
      }

      await batch.commit(noResult: true);
    });

    return items.length;
  }

  /// 导入一份商档 CSV（字节）。返回写入条数 / 跳过的行数。
  ///
  /// 拿到 0 条时**抛异常**：门店不可能一个商品都没有，
  /// 空清单意味着选错文件了 / 表头不对，必须让人看见 ——
  /// 静默返回 0 会让上一次的旧底表被当成"这次导进来的"。
  ///
  /// ── 为什么要把"跳过几行"带回去 ────────────────────────────────
  /// 条码为空的行会被跳过（那是数据问题，不是文件坏了）。不报出来的话，
  /// 员工看到的是"导入了 480 个商品"，而他手里那份表有 495 行 ——
  /// 少的 15 条**没人会知道**，直到某天扫到一个"未知条码"才起疑。
  /// 这类"少了几条"的问题最难查，所以数字必须当场给出来。
  Future<MasterImportResult> importCsv(List<int> bytes,
      {String source = sourceTag, bool purgeMissing = true}) async {
    final text = Gbk.decodeSmart(bytes);
    final parsed = MasterCsv.parse(text);
    if (parsed.items.isEmpty) {
      throw const FormatException(
          '这份文件里没读到任何商品。请确认：① 有一列叫「条码/商品条码/PLU」；'
          '② 那列不是空的。也可以先导出一份模板照着填。');
    }
    final db = await LocalDb.I.db();
    final n = await upsertAll(db, parsed.items,
        source: source, purgeMissing: purgeMissing);
    return MasterImportResult(
      written: n,
      skipped: parsed.skipped,
      total: parsed.total,
    );
  }

  /// 本地已有多少条商档（UI 显示"已导入 N 个商品"用）。
  Future<int> countLocal({String source = sourceTag}) async {
    final db = await LocalDb.I.db();
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS n FROM stock_master WHERE source = ?',
      [source],
    );
    final n = rows.first['n'];
    return n is int ? n : int.parse(n.toString());
  }

  /// 金额/库存统一转 double。
  ///
  /// mssql 的 decimal 经 CSV 会带成 `"83.00"` 这样的字符串；
  /// 不转就存进 SQLite 的话，后面算盈亏时 `"83.00" - 80` 直接出 NaN，
  /// 而且不报错、只是数字变得莫名其妙。
  static double? _num(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    final s = v.toString().trim().replaceAll(',', '');
    if (s.isEmpty) return null;
    return double.tryParse(s);
  }

  /// 给 [MasterCsv] 用的数值转换（它解析出来的是字符串）。
  static double? numOf(String s) => _num(s);
}

/// 一次商档导入的结果。
///
/// [skipped] 不为 0 时界面**必须报出来**（"跳过 N 行"）——
/// 见 [StockMasterRepo.importCsv] 里那段说明：少了几条没人知道，
/// 是最难查的一类问题。
class MasterImportResult {
  const MasterImportResult({
    required this.written,
    required this.skipped,
    required this.total,
  });

  /// 真正写进本地底的条数。
  final int written;

  /// 因为条码为空被跳过的行数。
  final int skipped;

  /// 读到的数据行数（不含表头）。
  final int total;
}

/// 商档 CSV 的**解析**与**模板**。
///
/// ── 为什么自己解析而不引 csv 包 ────────────────────────────────
/// 就为了读一份四列的表引一个依赖不划算；更要紧的是这里有几个
/// **通用 CSV 库不会替你做、但现场一定会踩**的处理，必须在自己手里：
///   ① 编码：国内 Win 上导出的默认是 GBK（见 [Gbk.decodeSmart]）
///   ② `="6921817824327"` 这种"Excel 文本公式"包裹（我们自己导出的
///      条码列就是这么写的，员工把导出的明细再导回来说是常事）
///   ③ 表头别名：融通/泰格/手工 Excel 三家叫法都不一样
///   ④ BOM：Excel 存的 UTF-8 带 BOM，不剥掉第一列名永远匹配不上
class MasterCsv {
  MasterCsv._();

  /// 标准列名（模板用，也是导入时**首选**的匹配名）。
  ///
  /// ── 2026-09-19 龙哥定的：只要 4 列 ──────────────────────────
  /// `序号 / 条码 / 商品名字 / 数量`。规格、单位、售价那几列在盘点场景里
  /// 用不上，留着只会让人填表时多打几列、还容易填错列。
  /// 「序号」是**给人看的**（对着纸质表核对行号），程序不读它 ——
  /// 所以它不在 [aliases] 里，解析时被忽略。
  static const List<String> headers = <String>[
    '序号',
    '条码',
    '商品名字',
    '数量',
  ];

  /// 无表头文件兜底时的列序（**不含序号**，因为它不被解析）。
  static const List<String> _noHeaderOrder = <String>[
    'barcode',
    'name',
    'account_qty',
  ];

  /// 列别名 → 内部字段。
  ///
  /// 匹配前会做规范化：去空格 / 下划线 / 连字符、转小写、去掉括号内容。
  /// 融通导出来叫「商品条码」、泰格可能叫「PLU」、手工表可能叫「条形码」——
  /// 认不过来的话，员工看到的是"导入成功但全是未知条码"，
  /// 那是把"表头没认出来"伪装成了"商档里没有这个商品"。
  static const Map<String, String> aliases = <String, String>{
    // 条码
    '条码': 'barcode',
    '条形码': 'barcode',
    '商品条码': 'barcode',
    '国际条码': 'barcode',
    '商品编码': 'barcode',
    '编码': 'barcode',
    '货号': 'barcode',
    'plu': 'barcode',
    'plucode': 'barcode',
    'barcode': 'barcode',
    'code': 'barcode',
    'ean': 'barcode',
    // 商品名字（模板列名；旧的"品名/商品名称"继续认，老文件不用改）
    '商品名字': 'name',
    '品名': 'name',
    '商品名称': 'name',
    '商品名': 'name',
    '名称': 'name',
    'name': 'name',
    // 规格
    '规格': 'spec',
    '规格型号': 'spec',
    '型号': 'spec',
    'spec': 'spec',
    // 单位
    '单位': 'unit',
    '计量单位': 'unit',
    'unit': 'unit',
    // 售价
    '售价': 'unit_price',
    '零售价': 'unit_price',
    '销售价': 'unit_price',
    '单价': 'unit_price',
    '价格': 'unit_price',
    'price': 'unit_price',
    'unitprice': 'unit_price',
    // 数量（模板列名）
    //
    // ⚠️ 导入语义上这一列是**账面数**（系统里现在有多少），不是实盘数。
    // 导出的扫码明细里也有「数量」列，但那是**实盘数**——把那份明细当商档
    // 导回来的话，账面=实盘，盈亏表会全变 0（看起来"盘得特别准"，其实没比对）。
    // 说明书里写了这条；列名叫"数量"是龙哥定的，不改。
    '数量': 'account_qty',
    // 账面数
    '账面数': 'account_qty',
    '账面数量': 'account_qty',
    '账面库存': 'account_qty',
    '账面': 'account_qty',
    '系统库存': 'account_qty',
    '库存数': 'account_qty',
    '库存': 'account_qty',
    'qty': 'account_qty',
    'accountqty': 'account_qty',
  };

  /// 解析后的结果。
  static MasterCsvResult parse(String text) => _parse(text);

  /// 一份可以直接照着填的模板（含 BOM，Excel 打开不乱码）。
  ///
  /// ⚠️ 示例行的条码**必须走 [barcodeCsvCell]**：模板是拿 Excel 打开照着填的，
  /// 不做保护的话 13 位条码会显示成 `6.92E+12` —— 员工看到的就是"模板坏了"，
  /// 然后自己手打一列不知道对不对的条码进去。（导出明细那边早就保护了，
  /// 模板这里之前漏了，2026-09-19 一并补上。）
  static String template() {
    final sb = StringBuffer('\uFEFF'); // BOM：Excel 靠它认 UTF-8
    sb.writeln(headers.map(csvEsc).join(','));

    String row(int serial, String barcode, String name, Object qty) =>
        <Object>[serial, csvEsc(barcodeCsvCell(barcode)), csvEsc(name), qty]
            .join(',');

    sb.writeln(row(1, '6921817824327', '示例商品A', 30));
    sb.writeln(row(2, '6901234567892', '示例商品B', 12));
    return sb.toString();
  }

  static String _norm(String s) => s
      .replaceAll(RegExp(r'[\s_\-（）()]'), '')
      .toLowerCase();

  /// 首列是不是「序号」（1,2,3… 一行不差地对下去）。
  ///
  /// ── 判据故意收得很窄 ────────────────────────────────────────
  /// 条码和序号**都是纯数字**，光看"是不是数字"分不开；写得松一点
  /// （比如"是数字且 ≤5 位"）就会把**店内自编码**（常见 4~5 位，如 1001、1002）
  /// 当成序号跳过去 —— 那一下整张表错位，导入"成功"但全是错的，
  /// 比直接报错难查得多。
  /// 所以只认"严格等于行号 + 至少两行"：条码极少恰好排成 1,2,3…
  static bool _hasSerialColumn(List<List<String>> rows) {
    if (rows.length < 2) return false; // 单行说明不了规律，宁可不跳
    for (var i = 0; i < rows.length; i++) {
      if (rows[i].isEmpty) return false;
      if (rows[i][0].trim() != '${i + 1}') return false;
    }
    return true;
  }

  /// 剥掉 Excel 的"文本公式"包裹：`="6921817824327"` → `6921817824327`。
  ///
  /// ── 为什么必须剥 ──────────────────────────────────────────────
  /// 我们自己导出的 CSV 里，条码列写的就是 `="6921817824327"`
  /// （见 [barcodeCsvCell]：不这么写，13 位条码在 Excel 里会变科学计数法）。
  /// 员工拿着导出的明细回头当商档导进来是很常见的动作，
  /// 不剥的话每个条码都变成一坨 `="6921817824327"`，一条都对不上账。
  static String _unwrap(String s) {
    var v = s.trim();
    // 去掉外层引号（CSV 转义出来的）
    if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
      v = v.substring(1, v.length - 1).replaceAll('""', '"');
    }
    v = v.trim();
    // 去掉 ="..."
    if (v.startsWith('=') && v.length >= 2) {
      var inner = v.substring(1).trim();
      if (inner.length >= 2 &&
          inner.startsWith('"') &&
          inner.endsWith('"')) {
        inner = inner.substring(1, inner.length - 1).replaceAll('""', '"');
      }
      return inner.trim();
    }
    return v;
  }

  static MasterCsvResult _parse(String text) {
    final rows = _splitRows(text);
    if (rows.isEmpty) {
      return const MasterCsvResult(items: [], skipped: 0, total: 0);
    }

    // 表头识别：第一行里能认出 ≥2 个已知列名才当它是表头。
    // 只认出 1 个就当没表头 —— 比如文件第一行恰好是"商品条码"四个字的
    // 说明性文字，把它当表头会把真正的数据行吃掉。
    final first = rows.first;
    final cols = <String?>[];
    var known = 0;
    for (final c in first) {
      final f = aliases[_norm(_unwrap(c))];
      cols.add(f);
      if (f != null) known++;
    }
    final hasHeader = known >= 2;

    final dataList = (hasHeader ? rows.skip(1) : rows).toList(growable: false);

    // 无表头时先判断首列是不是「序号」。判错会**整列错位**：
    // 条码被当成商品名、导入"成功"但一条都对不上 —— 比报错更难发现。
    final serialOffset = hasHeader ? 0 : (_hasSerialColumn(dataList) ? 1 : 0);
    final items = <Map<String, dynamic>>[];
    var skipped = 0;

    for (final r in dataList) {
      final m = <String, String>{};
      if (hasHeader) {
        for (var i = 0; i < r.length && i < cols.length; i++) {
          final f = cols[i];
          if (f == null) continue;
          m[f] = _unwrap(r[i]);
        }
      } else {
        // 无表头：按模板的列序（跳过序号列）
        for (var i = serialOffset;
            i < r.length && (i - serialOffset) < _noHeaderOrder.length;
            i++) {
          m[_noHeaderOrder[i - serialOffset]] = _unwrap(r[i]);
        }
      }

      final barcode = (m['barcode'] ?? '').trim();
      // 空条码导进去只会让员工扫到"未知商品"：那是把数据问题伪装成扫描问题。
      if (barcode.isEmpty) {
        skipped++;
        continue;
      }
      items.add(<String, dynamic>{
        'barcode': barcode,
        'name': (m['name'] ?? '').trim(),
        'spec': (m['spec'] ?? '').trim(),
        'unit': (m['unit'] ?? '').trim(),
        'unit_price': StockMasterRepo.numOf(m['unit_price'] ?? ''),
        'account_qty': StockMasterRepo.numOf(m['account_qty'] ?? ''),
      });
    }

    return MasterCsvResult(
      items: items,
      skipped: skipped,
      total: dataList.length,
    );
  }

  /// 把 CSV 文本切成"行 → 列"，认引号、认 CRLF、自动认分隔符。
  ///
  /// 分隔符自动判：表头行里 `;` 比 `,` 多就按 `;`（欧版 Excel 的习惯），
  /// 一个 `,` 都没有但有多个 `\t` 就按制表符（"从 Excel 复制粘贴出来"的
  /// 那种文本）。判错的代价是整行变成一个字段，所以宁可多判一道。
  static List<List<String>> _splitRows(String text) {
    var t = text;
    if (t.isNotEmpty && t.codeUnitAt(0) == 0xFEFF) t = t.substring(1); // BOM

    final firstLine = t.split(RegExp(r'\r?\n')).firstWhere(
          (l) => l.trim().isNotEmpty,
          orElse: () => '',
        );
    var sep = ',';
    final nComma = ','.allMatches(firstLine).length;
    final nSemi = ';'.allMatches(firstLine).length;
    final nTab = '\t'.allMatches(firstLine).length;
    if (nSemi > nComma) sep = ';';
    if (nComma == 0 && nTab > 0) sep = '\t';

    final out = <List<String>>[];
    final row = <String>[];
    final cur = StringBuffer();
    var inQuote = false;

    void endCell() {
      row.add(cur.toString());
      cur.clear();
    }

    void endRow() {
      endCell();
      // 全空行不要（Excel 导出的末尾常有一个空行，留着会多一条"空商品"）
      if (row.any((c) => c.trim().isNotEmpty)) out.add(List<String>.of(row));
      row.clear();
    }

    for (var i = 0; i < t.length; i++) {
      final c = t[i];
      if (inQuote) {
        if (c == '"') {
          // "" = 转义的引号；否则是这一格的结束
          if (i + 1 < t.length && t[i + 1] == '"') {
            cur.write('"');
            i++;
          } else {
            inQuote = false;
          }
        } else {
          cur.write(c);
        }
        continue;
      }
      if (c == '"') {
        inQuote = true;
        continue;
      }
      if (c == sep) {
        endCell();
        continue;
      }
      if (c == '\n') {
        endRow();
        continue;
      }
      if (c == '\r') {
        // \r\n 与裸 \r（老 Mac）都算换行
        if (i + 1 < t.length && t[i + 1] == '\n') i++;
        endRow();
        continue;
      }
      cur.write(c);
    }
    // 最后一行没有换行结尾时也要收进来
    if (cur.isNotEmpty || row.isNotEmpty) endRow();

    return out;
  }
}

/// [MasterCsv.parse] 的结果。
class MasterCsvResult {
  const MasterCsvResult({
    required this.items,
    required this.skipped,
    required this.total,
  });

  /// 解析出来的商品（可直接落库）。
  final List<Map<String, dynamic>> items;

  /// 因为条码为空而跳过的行数（界面上要报出来，否则"少了几条"没人知道）。
  final int skipped;

  /// 读到的数据行数（不含表头）。
  final int total;
}
