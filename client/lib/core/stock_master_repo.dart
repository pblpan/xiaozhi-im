import 'package:sqflite/sqflite.dart';
import 'package:xiaozhi_im_client/api.dart';
import 'package:xiaozhi_im_client/core/local_db.dart';
import 'package:xiaozhi_im_client/core/wake_lock.dart';

/// 商品档案（商档）的本地仓库：从泰格拉下来，落进本地 `stock_master` 表。
///
/// 为什么它必须是独立的本地表，而不是每次现查接口：
/// 扫码发生在货架之间，那里的网络状况不归我们管。员工扫一个条码，
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

  /// 从自家服务端 `/api/master` 拉下来的商档（现在的正路）。
  static const String sourceServer = 'server';

  /// 服务端同步期间的**暂存表**：全部拉完才整表搬进 stock_master，
  /// 中途失败就把整张表丢掉（正式底表一行不动）。
  static const String stagingTable = 'stock_master_staging';

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
        // 供应商（龙哥 2026-10-12）：上游带了就带上，没带落空串。
        'supplier': (raw['supplier'] ?? '').toString(),
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
  /// （商品下架了，本地还留着它的账面数，扫码时会凭空多出一行）。
  ///
  /// 🔴 但 `items` 为空时**一律不清理**：一次网络抖动/上游返回空，
  /// 不能把整张底表清空 —— 宁可留旧数据，也不能让员工扫什么都是"未知商品"。
  static Future<int> upsertAll(
    Database db,
    List<Map<String, dynamic>> items, {
    String table = 'stock_master',
    String source = sourceTag,
    bool purgeMissing = true,
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;

    await db.transaction((txn) async {
      final batch = txn.batch();
      for (final it in items) {
        batch.insert(
          table,
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
          table,
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

  /// 从**自家服务端**拉商档（现在的正路）。
  ///
  /// 为什么不再只靠泰格上游：那个桥接跑在一台会关机、IP 会漂的机器上，
  /// 一断就是"初盘每一行都没有账面数" → 差异集 = 全部商品 → 三遍制白盘。
  /// 商档是门店自己的底表，放自家服务端最合适：管理台导入一次，全员同一份。
  ///
  /// 🔴 为什么要先写进 `staging` 再转正：
  /// 🔴 暂存必须用**另一张表**，不能靠 source 字段区分：
  ///    `stock_master` 的主键就是 `barcode`（不是 barcode+source），
  ///    所以往同一张表里写"暂存的 69001"会把正式的 69001 直接替换掉 ——
  ///    拉到一半失败时再把暂存一删，等于把上一次那份完整底表也一起删了。
  ///    这个坑比"拉到一半"本身更狠：手机上会变成**一个商品都没有**。
  ///    独立暂存表 + 最后一次性搬家，失败就丢掉整张暂存表，正式表一行不动。
  static Future<int> syncFromServer({
    void Function(int done, int total)? onProgress,
    int pageSize = 2000,
    // 只为测试可注入假实现；生产不传，走 ImApi 的真实接口。
    Future<Map<String, dynamic>> Function()? countCall,
    Future<Map<String, dynamic>> Function(int page, int pageSize)? pageCall,
  }) async {
    // 🔴 下载商档期间屏幕常亮（龙哥 2026-10-13：息屏 = Doze = CPU/网络挂起，
    //    几万行的分页拉取必被打断）。盘点/拣货/商档查询三处入口都走本函数，
    //    保活收在这里 = 一处覆盖全部；成功/失败/取消都必须把控制权还回去。
    await WakeLock.enable();
    try {
      return await _syncFromServerImpl(
        onProgress: onProgress,
        pageSize: pageSize,
        countCall: countCall,
        pageCall: pageCall,
      );
    } finally {
      await WakeLock.disable();
    }
  }

  static Future<int> _syncFromServerImpl({
    void Function(int done, int total)? onProgress,
    int pageSize = 2000,
    Future<Map<String, dynamic>> Function()? countCall,
    Future<Map<String, dynamic>> Function(int page, int pageSize)? pageCall,
  }) async {
    final api = ImApi();
    final head = await (countCall ?? api.masterCount)();
    final total = head['total'] is int
        ? head['total'] as int
        : int.tryParse('${head['total']}') ?? 0;
    if (total <= 0) {
      throw const StateException(
          '服务端还没有商品档案。请让管理员在管理台「商品档案」里导入一次 CSV，'
          '手机再来同步。');
    }

    final db = await LocalDb.I.db();
    await db.execute('DROP TABLE IF EXISTS $stagingTable');
    await db.execute('''
      CREATE TABLE $stagingTable (
        barcode TEXT PRIMARY KEY,
        name TEXT,
        spec TEXT,
        unit TEXT,
        unit_price REAL,
        purchase_price REAL,
        member_price REAL,
        special_price REAL,
        account_qty REAL,
        supplier TEXT,
        source TEXT,
        updated_at INTEGER
      )
    ''');

    int done = 0;
    try {
      for (int page = 1;; page++) {
        final envelope = await (pageCall ?? api.masterPage)(page, pageSize);
        final raw = envelope['items'];
        final items = raw is List ? raw : const <dynamic>[];
        if (items.isEmpty) break;

        final rows = <Map<String, dynamic>>[];
        for (final e in items) {
          if (e is! Map) continue;
          final bc = (e['barcode'] ?? '').toString().trim();
          if (bc.isEmpty) continue;
          rows.add(<String, dynamic>{
            'barcode': bc,
            'name': e['name'],
            'spec': e['spec'],
            'unit': e['unit'],
            'unit_price': e['unit_price'],
            // 🔴 进价必须一起落库（标准六列之一）。漏掉的话同步完本地表
            //    这列永远为空，而它**不报错也不警告** —— 服务端 2026-09-26
            //    那次就是这么丢掉规格和单位的，直到要按单位判称重口径才发现。
            'purchase_price': e['purchase_price'],
            // 会员价/特价（龙哥 2026-10-06）：同进价一个道理，这里不带，
            // 本地就永远查不到，商档查询页那两行就是空的。
            'member_price': e['member_price'],
            'special_price': e['special_price'],
            'account_qty': e['account_qty'],
            // 供应商（龙哥 2026-10-12）：服务端 2026-10-10 就带了这列，
            // 客户端这条链路没接，商档查询页永远显示不出来。
            'supplier': e['supplier'],
          });
        }
        if (rows.isEmpty) break;

        // 分块写入期间**不清理**（purgeMissing=false）：
        // 一清理就把前几页刚写进去的行当成"清单里没有"删掉了。
        await upsertAll(db, rows,
            table: stagingTable, source: sourceServer, purgeMissing: false);
        done += rows.length;
        onProgress?.call(done, total);
        if (envelope['has_more'] != true) break;
      }
    } catch (e) {
      // 拉一半失败：整张暂存表丢掉，正式底表一行不动
      await db.execute('DROP TABLE IF EXISTS $stagingTable');
      rethrow;
    }

    // 搬家：整表替换。商档就是"全量对齐"语义，没有"合并"这一说 ——
    // 下架的商品不该还留着账面数，否则盘点时会凭空多出一行。
    //
    // 🔴🔴 列清单必须把**价格三兄弟全带上**（进价/会员价/特价）：
    //    2026-10-06 之前这里漏了 purchase_price —— 暂存表里明明写进去了，
    //    INSERT…SELECT 的列清单没带它，搬完的正式表这一列全是 NULL。
    //    商档查询页"进货价"从此一直显示不出来，而同步成功、条数都对，
    //    **没有任何报错** —— 这是本轮五修里最隐蔽的一个 bug。
    //    教训：staging 表加列时，搬家 SQL 必须同一次改，两处只改一处 = 静默丢列。
    // 🔴 2026-10-12 供应商 supplier 同款教训：staging 建表和分页行解析都带了，
    //    搬家 SQL 又漏了 —— 三处必须一次改齐，漏一处 = 静默丢列。
    await db.transaction((txn) async {
      await txn.delete('stock_master');
      await txn.rawInsert(
        'INSERT INTO stock_master '
        '(barcode, name, spec, unit, unit_price, purchase_price, '
        'member_price, special_price, account_qty, supplier, source, updated_at) '
        'SELECT barcode, name, spec, unit, unit_price, purchase_price, '
        'member_price, special_price, account_qty, supplier, source, updated_at '
        'FROM $stagingTable',
      );
    });
    await db.execute('DROP TABLE IF EXISTS $stagingTable');
    return done;
  }

  /// 本地已有多少条商档（默认只数 [sourceTag] 那一份）。
  ///
  /// 不同来源可以**按条码共存**（69001 来自泰格、69002 是手工补的），
  /// 所以"本来源有多少"是个有意义的数，别默认数全表。
  Future<int> countLocal({String source = sourceTag}) async {
    final db = await LocalDb.I.db();
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS n FROM stock_master WHERE source = ?',
      [source],
    );
    final n = rows.first['n'];
    return n is int ? n : int.parse(n.toString());
  }

  /// 本地商档总数（**不分来源**）。
  ///
  /// 🔴 界面上"已同步 N 个商品"必须用它，不能用 [countLocal]：
  ///    从服务端同步下来的商档 source 是 `server`，而 countLocal 默认数 tiger，
  ///    同步完了界面还显示"0 个商品"，人会以为同步白做了。
  Future<int> countAll() async {
    final db = await LocalDb.I.db();
    final rows = await db.rawQuery('SELECT COUNT(*) AS n FROM stock_master');
    final n = rows.first['n'];
    return n is int ? n : int.parse(n.toString());
  }

  /// 本地查一个条码的商档（断网也能用）。查不到返回 null。
  ///
  /// 扫码确认卡、商档查询都用它当场回答"这是什么、规格单位是什么"。
  Future<Map<String, dynamic>?> lookupLocal(String barcode) async {
    final db = await LocalDb.I.db();
    final rows = await db.query(
      'stock_master',
      where: 'barcode = ?',
      whereArgs: [barcode.trim()],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// 全局单例：扫码页 / 拣货页等需要就地查商档时直接用，不用每次 new。
  static final StockMasterRepo instance = StockMasterRepo();
}

/// 用一个明确的异常类型区分"业务上不该发生"，方便上层单独处理。
class StateException implements Exception {
  final String message;
  const StateException(this.message);

  @override
  String toString() => message;
}
