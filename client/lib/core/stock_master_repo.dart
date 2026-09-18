import 'package:sqflite/sqflite.dart';
import 'package:xiaozhi_im_client/api.dart';
import 'package:xiaozhi_im_client/core/local_db.dart';

/// 商品档案（商档）的本地仓库：从泰格拉下来，落进本地 `stock_master` 表。
///
/// 为什么它必须是独立的本地表，而不是每次现查接口：
/// 盘点发生在货架之间，那里的网络状况不归我们管。员工扫一个条码，
/// 手机必须**当场**回答"这是什么、系统账面多少" —— 这两件事都查不了服务端。
/// 所以商档要先整份落到本地 SQLite（见 core/local_db.dart 的 stock_master），
/// 断网时照样能盘，联网后再把扫码流水回传。
///
/// 取数走小智的**上游转发通道** `/api/hooks/up/<名字>/<子路径>`：
/// 客户端拿不到泰格的真实地址（防 SSRF），只认服务端登记过的名字。
///
/// 🔴 回包是**带外壳**的：`{ ok, upstream, url, status, ms, truncated, data }`，
///    真正的清单在 `data.items` 里。把它当裸数组直接用，表格/落库会永远是空的 ——
///    这是这条通道最容易踩的一处（服务端那边同样要求 dataPath 必带 `data.` 前缀）。
typedef UpstreamCall = Future<dynamic> Function(
  String path, {
  String method,
  Map<String, dynamic>? body,
});

class StockMasterRepo {
  /// 服务端登记的上游名字是 `tiger`，子路径 `master/items` 由 tiger-bridge 提供。
  static const String defaultPath = '/hooks/up/tiger/master/items';

  /// 区分"这份数据是谁给的"。将来若接第二个来源（比如手工维护的 Excel），
  /// 靠它隔离，互不覆盖。
  static const String sourceTag = 'tiger';

  final UpstreamCall _call;
  final String path;

  /// [call] 只为了测试可注入假实现；生产不传，走 ImApi 的真实上游通道。
  StockMasterRepo({UpstreamCall? call, this.path = defaultPath})
      : _call = call ?? _defaultCall;

  static Future<dynamic> _defaultCall(String p,
      {String method = 'GET', Map<String, dynamic>? body}) {
    return ImApi().hookCall(p, method: method, body: body);
  }

  /// 从上游回包里取出商档清单。
  ///
  /// 故意做成**抛异常而不是返回空数组**：外壳缺 `data`、或 `items` 不是数组时，
  /// 返回 `[]` 会让上层以为"同步成功、店里 0 个商品"——
  /// 一次接口结构变化就被渲染成"库存清空"，是最难查的一类事故。
  static List<Map<String, dynamic>> parseItems(dynamic envelope) {
    if (envelope is! Map) {
      throw const FormatException('商档回包不是 JSON 对象');
    }
    final data = envelope['data'];
    if (data is! Map) {
      throw const FormatException(
          '商档回包缺少 data 外壳（应为 { ok, ..., data: { items: [...] } }）');
    }
    final items = data['items'];
    if (items is! List) {
      throw const FormatException('data.items 不是数组');
    }

    final out = <Map<String, dynamic>>[];
    for (final raw in items) {
      if (raw is! Map) continue;
      final barcode = (raw['barcode'] ?? '').toString().trim();
      // 空条码下发下来只会让员工扫到"未知商品"：那是把数据问题伪装成扫描问题。
      if (barcode.isEmpty) continue;
      out.add(<String, dynamic>{
        'barcode': barcode,
        'name': (raw['name'] ?? '').toString(),
        'spec': (raw['spec'] ?? '').toString(),
        'unit': (raw['unit'] ?? '').toString(),
        'unit_price': _num(raw['unit_price']),
        'account_qty': _num(raw['account_qty']),
      });
    }
    return out;
  }

  /// 金额/库存统一转 double。
  ///
  /// mssql 的 decimal 经 JSON 会带成 `"83.00"` 这样的字符串；
  /// 不转就存进 SQLite 的话，后面算盈亏时 `"83.00" - 80` 直接出 NaN，
  /// 而且不报错、只是数字变得莫名其妙。
  static double? _num(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }

  /// 把整份商档写进本地表。返回写入条数。
  ///
  /// [purgeMissing] = 真时，会把**同一来源**下不在本次清单里的旧记录删掉
  /// （商品下架了，本地还留着它的账面数，盘点时会凭空多出一行）。
  ///
  /// 🔴 但 `items` 为空时**一律不清理**：一次网络抖动/上游返回空，
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

  /// 拉一次商档并落库。
  ///
  /// 拿到 0 条时**抛异常**：门店不可能一个商品都没有，
  /// 空清单意味着上游登记错了 / 门店号不对 / 接口结构变了，必须让人看见。
  Future<int> sync() async {
    final envelope = await _call(path);
    final items = parseItems(envelope);
    if (items.isEmpty) {
      throw StateException(
          '商档同步拿到 0 条（path=$path）。不覆盖本地底表——'
          '请检查上游登记的地址与门店号，别让一次空响应清空库存底表。');
    }
    final db = await LocalDb.I.db();
    return upsertAll(db, items);
  }

  /// 本地已有多少条商档（UI 显示"已同步 N 个商品"用）。
  Future<int> countLocal({String source = sourceTag}) async {
    final db = await LocalDb.I.db();
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS n FROM stock_master WHERE source = ?',
      [source],
    );
    final n = rows.first['n'];
    return n is int ? n : int.parse(n.toString());
  }
}

/// 用一个明确的异常类型区分"业务上不该发生"，方便上层单独处理。
class StateException implements Exception {
  final String message;
  const StateException(this.message);

  @override
  String toString() => message;
}
