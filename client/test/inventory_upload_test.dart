import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xiaozhi_im_client/api.dart';
import 'package:xiaozhi_im_client/core/config.dart';
import 'package:xiaozhi_im_client/core/local_db.dart';
import 'package:xiaozhi_im_client/screens/inventory_collect.dart';

import 'support/api_stub.dart';

/// 采集页「回传服务端 / 提交审批」的测试。
///
/// ── 钉住的是哪几件事 ────────────────────────────────────────────
/// ① 上传的**请求体**是对的：`phase` / `zone` / 每行的
///    `barcode·qty·account_qty·loc_code·scanned_at` / `bindings` / `Bearer tok`。
///    这些字段错了服务端**不会报错**，只会收下一份错的数据，
///    然后所有下游（差异表、审批、后台）全跟着错 —— 所以逐个钉。
/// ② 传成功后**本地也归档**（status=2），按钮换成「提交审批到主管」。
///    本地不归档的话，重传时服务端 409、员工以为没传上去，会反复点。
/// ③ 服务端回 409 `already_uploaded` = 数据确实在服务端 ⇒ 本地也归档，
///    但**必须明说"没有覆盖"**。静默当成成功，等于把
///    "本地这份和服务端那份不一样"这件事藏起来。
/// ④ 服务端回 400 `not_in_diff_set` ⇒ **本地绝不能归档**（数据没进服务端），
///    并把被拒的条码逐条列出来。归档了就变成"单子写着已上传、实际少东西"。
/// ⑤ 没登录就不发请求（省得撞一个 401 再解释一遍）。
/// ⑥ 提审要带 `kind=stocktake` + `ref=单号`；成功/重复提审都转成
///    "已提交审批"的气口，而不是红着脸报错 —— 重复提审其实是**正常结果**。
/// ⑦ 上传后**不再给"撤销提交"**：服务端已归档，本地放回可改
///    只会造成"改了却传不上去"，两边对不上。
///
/// ── 真 IO 的纪律（踩过）────────────────────────────────────────
/// · 页面读真 SQLite（走 isolate/FFI）、请求走真 socket：
///   两者都要 `tester.runAsync` 借真实时间，光 `pump` 永远是"没反应"。
/// · 断言一律**等条件成立**（按钮变了 / 文案出现了），不用固定帧数凑 ——
///   固定帧数在慢机器上会偶发失败，然后被人当成"界面坏了"。
/// · SnackBar 有 4 秒定时器，测试结束还挂着会判 "A Timer is still pending"，
///   收尾统一走 [drain]。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 🔴 2026-10-03 补：shared_preferences 的 mock。
  //   多企业改造后 `ImApi._h` 改为**读激活档案的 token**（而不再读全局 `_token`），
  //   于是任何走 ImApi 的路径都会碰到 SessionManager → SharedPreferences.getInstance()。
  //   单元测试里没有 plugin 实现，会抛
  //     MissingPluginException(No implementation found for method getAll
  //                             on channel plugins.flutter.io/shared_preferences)
  //   而且它是在**测试已经结束后**才抛的（报错是 "failed after test completion"），
  //   8 个用例一起挂、且看不出跟偏好有关 —— 很容易误判成"页面坏了"。
  //   修法是补上 mock（沿用 workspace_test / widget_test 的既有写法），
  //   而不是把 _h 改回去 —— 改回去等于把"切企业后全 401"那个 bug 请回来。
  SharedPreferences.setMockInitialValues({});

  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  final supportDir = '${Directory.systemTemp.path}/xz_inventory_upload_test';
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(pathChannel, (call) async {
    if (call.method == 'getApplicationSupportDirectory') return supportDir;
    return null;
  });

  late ApiStub stub;

  setUp(() async {
    stub = await ApiStub.start();
    Config.currentUrl = stub.baseUrl;
    ImApi().setToken('tok');
    await _seed();
  });

  tearDown(() async {
    ImApi().clearToken();
    await stub.stop();
  });

  // ============================================================
  // 基建
  // ============================================================

  /// 等条件成立。每轮**借一点真实时间**（runAsync）再推一帧假时钟。
  Future<void> waitFor(
    WidgetTester tester,
    bool Function() ok, {
    int tries = 240,
    required String why,
  }) async {
    for (var i = 0; i < tries; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)));
      await tester.pump(const Duration(milliseconds: 25));
      if (ok()) return;
    }
    fail('等待超时：$why');
  }

  /// 走动画/提示用的推帧（同样带真实时间，否则 DB 回包到不了）。
  Future<void> settleAnim(WidgetTester tester, {int frames = 12}) async {
    for (var i = 0; i < frames; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump(const Duration(milliseconds: 40));
    }
  }

  /// 等所有 SnackBar 散掉。
  ///
  /// 🔴 **底部浮动的 SnackBar 会压住底部那颗主按钮**（真机上也一样）：
  ///    扫完一件会弹"已记上"，此时点「上传/提交」，命中到的是提示条，
  ///    按钮的 onPressed 根本不会触发 —— 表现成"点了没反应"。
  ///    所以点底部按钮之前必须先把提示等散。
  ///    一次 pump 直接跳 5 秒假时钟（一条提示 4 秒），比一帧帧等快得多。
  Future<void> waitSnackClear(WidgetTester tester) async {
    for (var i = 0; i < 40; i++) {
      if (find.byType(SnackBar).evaluate().isEmpty) return;
      await tester.pump(const Duration(seconds: 5));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)));
    }
    fail('SnackBar 一直没散（可能某处在反复弹提示）');
  }

  /// 收尾：把还挂着的假时钟定时器走完（SnackBar 4 秒 / ImApi 15 秒超时）。
  Future<void> drain(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 16));
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump(const Duration(milliseconds: 60));
  }

  Future<Map<String, dynamic>?> sheetRow(WidgetTester tester) async {
    Map<String, dynamic>? out;
    await tester.runAsync(() async {
      final db = await LocalDb.I.db();
      final r = await db.query('stocktake_sheet', limit: 1);
      out = r.isEmpty ? null : r.first;
    });
    return out;
  }

  Future<int?> statusOf(WidgetTester tester) async =>
      ((await sheetRow(tester))?['status'] as num?)?.toInt();

  /// 本地流水里某个条码记了几行（真 IO）。
  Future<int> rowsOfBarcode(WidgetTester tester, String barcode) async {
    var n = 0;
    await tester.runAsync(() async {
      final db = await LocalDb.I.db();
      final r = await db.query('scan_record',
          where: 'barcode = ?', whereArgs: <Object?>[barcode]);
      n = r.length;
    });
    return n;
  }

  /// 已回传的行数。
  Future<int> scanRowsUploaded(WidgetTester tester) async {
    var n = 0;
    await tester.runAsync(() async {
      final db = await LocalDb.I.db();
      final r = await db.query('scan_record', where: 'uploaded = 1');
      n = r.length;
    });
    return n;
  }

  Future<void> pumpPage(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: InventoryCollectPage(zoneCode: 'Z01', zoneName: '生鲜区'),
    ));
    await tester.pump();
    await waitFor(
      tester,
      () => find.byType(CircularProgressIndicator).evaluate().isEmpty,
      why: '页面一直停在 loading：DB 初始化没在预期次数内完成',
    );
  }

  /// 扫一枪（扫码枪那条路：输入框 + 回车）。
  ///
  /// 🔴 等的是**本地流水真的落了这一行**，不是"屏幕上出现了这个条码"：
  ///    输入框里此刻也写着同一个字符串，看屏幕等于恒真 ——
  ///    于是后面所有断言都在"还没扫进去"的状态下跑，报错指向的地方全是错的。
  Future<void> scan(WidgetTester tester, String code) async {
    await tester.enterText(find.byKey(const Key('inv-scan-input')), code);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    var n = 0;
    for (var i = 0; i < 200 && n == 0; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)));
      await tester.pump(const Duration(milliseconds: 25));
      n = await rowsOfBarcode(tester, code);
    }
    if (n == 0) fail('扫了 $code，本地流水里没有它');
    // 再等**明细行**渲染出来：提交按钮的可用性看的是界面上的 `_rows`，
    // 不是库里有没有 —— 库里有了、界面还没刷，按钮仍是灰的（点了没反应）。
    await waitFor(tester,
        () => find.byKey(Key('inv-row-$code')).evaluate().isNotEmpty,
        why: '扫了 $code，明细行没渲染出来');
  }

  /// 点确认框里的某个按钮。
  ///
  /// 🔴 先**等这个按钮真的出现**再点。确认框常常不是在点下去那一帧就有的 ——
  ///    中间还夹着真 IO（提交要写库、上传要发请求），
  ///    直接点会得到"找不到控件"，看着像界面坏了，其实是没等够。
  Future<void> tapInDialog(WidgetTester tester, String label) async {
    final f = find.descendant(
        of: find.byType(AlertDialog), matching: find.text(label));
    await waitFor(tester, () => f.evaluate().isNotEmpty,
        why: '确认框里的「$label」一直没出现');
    await tester.tap(f);
    await settleAnim(tester);
  }

  /// 扫两件 → 提交（本地锁单）→ 丢掉"现在开始复盘？"，停在 status=1。
  Future<String> scanAndSubmit(WidgetTester tester) async {
    await scan(tester, '6901');
    await scan(tester, '6902');
    await waitSnackClear(tester);
    await tester.tap(find.byKey(const Key('inv-submit')));
    await settleAnim(tester);
    await tapInDialog(tester, '提交');
    expect(await statusOf(tester), 1, reason: '提交后本地应当锁单（status=1）');
    // 初盘提交后一定会问"现在开始复盘？"—— 这里不去，留在初盘。
    await tapInDialog(tester, '待会儿');
    final s = await sheetRow(tester);
    return s!['sheet_no'] as String;
  }

  void stubUpload(String no, Object? Function(StubCall) h) =>
      stub.on('POST', '/api/stocktake/sheet/$no/upload', h);

  Map<String, dynamic> okUpload() => <String, dynamic>{
        'ok': true,
        'received': 2,
        'accepted': 2,
        'rejected': <dynamic>[],
        'diff_checked': false,
      };

  /// 走完"上传"这一步（点按钮 + 确认 + 等归档）。
  Future<void> doUpload(WidgetTester tester, String no) async {
    await waitSnackClear(tester);
    await waitSnackClear(tester);
    await tester.tap(find.byKey(const Key('inv-upload')));
    await settleAnim(tester);
    await tapInDialog(tester, '上传');
    await waitFor(
        tester,
        () => find.byKey(const Key('inv-submit-approval')).evaluate().isNotEmpty,
        why: '上传成功后主按钮应当变成「提交审批到主管」');
  }

  // ============================================================
  // ① 请求体正确 + 本地归档
  // ============================================================

  testWidgets('① 上传：请求体字段正确，本地归档，按钮转「提交审批到主管」', (tester) async {
    await pumpPage(tester);
    final no = await scanAndSubmit(tester);
    expect(find.byKey(const Key('inv-upload')), findsOneWidget,
        reason: '提交之后主按钮应当变成「上传到服务端」');

    stubUpload(no, (c) => okUpload());
    await doUpload(tester, no);

    // ── 请求真的发出去了，而且字段一个不差 ──
    expect(stub.hits('POST', '/api/stocktake/sheet/$no/upload'), 1,
        reason: '点「上传」必须真的发出 POST');
    final c = stub.last('POST', '/api/stocktake/sheet/$no/upload');
    expect(c.authorization, 'Bearer tok', reason: '上传必须带登录态');
    final b = c.body as Map<String, dynamic>;
    expect(b['phase'], 1);
    expect((b['zone'] as Map)['zone_code'], 'Z01');
    expect((b['zone'] as Map)['zone_name'], '生鲜区');

    final rows = (b['rows'] as List).cast<Map<String, dynamic>>();
    expect(rows.length, 2, reason: '扫了两种就传两种');
    final r1 = rows.firstWhere((r) => r['barcode'] == '6901');
    expect(r1['qty'], 1);
    // 账面数只是参考列，但必须带上：后台要靠它对照
    expect(r1['account_qty'], 10.0, reason: '账面数要从商档缓存带出去');
    expect(r1['loc_code'], 'A01',
        reason: '要记下"在哪儿数出来的"——没有货架位，差异出来没人知道去哪找');
    expect(r1['scanned_at'], isNotNull,
        reason: '扫描时刻要传真实的，不能落成上传时刻');

    final binds = (b['bindings'] as List).cast<Map<String, dynamic>>();
    expect(binds.any((x) => x['barcode'] == '6901' && x['loc_code'] == 'A01'),
        isTrue,
        reason: '点位内的货架位绑定要顺带补上去');

    // ── 本地也归档 ──
    expect(await statusOf(tester), 2,
        reason: '上传成功后本地必须归档，否则会反复重传');
    expect(await scanRowsUploaded(tester), 2,
        reason: '两行流水的 uploaded 标记要一起翻（只翻单头会出现"单已归档、行还是未传"）');
    expect(find.byKey(const Key('inv-submit-approval')), findsOneWidget);
    await drain(tester);
  });

  testWidgets('② 上传后不再给「撤销提交」（服务端已归档，本地回不去）', (tester) async {
    await pumpPage(tester);
    final no = await scanAndSubmit(tester);
    expect(find.byKey(const Key('inv-reopen')), findsOneWidget,
        reason: '已提交、还没上传时，撤销提交要能用');

    stubUpload(no, (c) => okUpload());
    await doUpload(tester, no);

    expect(find.byKey(const Key('inv-reopen')), findsNothing,
        reason: '已归档的单不该给"撤销提交"——本地放回可改只会造成改了却传不上去');
    await drain(tester);
  });

  // ============================================================
  // ③ 409 已上传过
  // ============================================================

  testWidgets('③ 409 already_uploaded：本地也归档，但明说「没有覆盖」', (tester) async {
    await pumpPage(tester);
    final no = await scanAndSubmit(tester);

    stubUpload(
        no,
        (c) => const StubResponse(409, <String, dynamic>{
              'error': '该盘点单已上传过，如需覆盖请显式传 force=1',
              'code': 'already_uploaded',
              'sheet_no': 'x',
            }));

    await waitSnackClear(tester);
    await tester.tap(find.byKey(const Key('inv-upload')));
    await settleAnim(tester);
    await tapInDialog(tester, '上传');

    await waitFor(tester, () => find.textContaining('没有覆盖').evaluate().isNotEmpty,
        why: '409 之后应当明说这次没有覆盖服务端');
    expect(await statusOf(tester), 2,
        reason: '409 表示服务端已经有这张单 = 数据在服务端，本地要归档');
    await drain(tester);
  });

  // ============================================================
  // ④ 400 不在复核清单
  // ============================================================

  testWidgets('④ 400 not_in_diff_set：本地绝不能归档，并列出被拒条码', (tester) async {
    await pumpPage(tester);
    final no = await scanAndSubmit(tester);

    stubUpload(
        no,
        (c) => const StubResponse(400, <String, dynamic>{
              'error': '抽盘阶段只复核初盘与复盘对不上的商品',
              'code': 'not_in_diff_set',
              'barcodes': <String>['6902'],
              'total_bad': 1,
            }));

    await waitSnackClear(tester);
    await tester.tap(find.byKey(const Key('inv-upload')));
    await settleAnim(tester);
    await tapInDialog(tester, '上传');

    await waitFor(tester, () => find.textContaining('6902').evaluate().isNotEmpty,
        why: '要列出被拒的条码，否则员工不知道去改哪一行');
    expect(await statusOf(tester), 1,
        reason: '被服务端拒收 = 数据没进服务端，本地**不能**标成已上传');
    expect(find.byKey(const Key('inv-upload')), findsOneWidget,
        reason: '主按钮要留在「上传到服务端」，让人能改完重传');
    await drain(tester);
  });

  // ============================================================
  // ⑤ 没登录不发请求
  // ============================================================

  testWidgets('⑤ 没登录：一个请求都不发，明说先去登录', (tester) async {
    ImApi().clearToken();
    await pumpPage(tester);
    final no = await scanAndSubmit(tester);

    await waitSnackClear(tester);
    await tester.tap(find.byKey(const Key('inv-upload')));
    await settleAnim(tester);

    await waitFor(tester, () => find.textContaining('还没登录').evaluate().isNotEmpty,
        why: '没登录应当明说，而不是发一个注定 401 的请求');
    expect(stub.hits('POST', '/api/stocktake/sheet/$no/upload'), 0,
        reason: '没登录就不该发请求');
    expect(await statusOf(tester), 1, reason: '没传上去就不能归档');
    await drain(tester);
  });

  // ============================================================
  // ⑥ 提交审批
  // ============================================================

  testWidgets('⑥ 提交审批：带 kind/ref，成功后按钮转「已提交审批」', (tester) async {
    await pumpPage(tester);
    final no = await scanAndSubmit(tester);
    stubUpload(no, (c) => okUpload());
    await doUpload(tester, no);

    stub.on(
        'POST',
        '/api/approval/submit',
        (c) => <String, dynamic>{
              'approval': <String, dynamic>{
                'id': 1,
                'kind': 'stocktake',
                'ref': no,
                'status': 'pending',
              }
            });

    await waitSnackClear(tester);
    await tester.tap(find.byKey(const Key('inv-submit-approval')));
    await settleAnim(tester);
    await tapInDialog(tester, '提交');

    await waitFor(tester, () => stub.hits('POST', '/api/approval/submit') == 1,
        why: '提审必须真的发出去');
    final b =
        stub.last('POST', '/api/approval/submit').body as Map<String, dynamic>;
    expect(b['kind'], 'stocktake');
    expect(b['ref'], no, reason: 'ref 必须是盘点单号，服务端靠它找单');
    expect(b['title'], contains('生鲜区'));

    await waitFor(tester, () => find.text('已提交审批').evaluate().isNotEmpty,
        why: '提审成功后按钮要变成"已提交审批"');
    await drain(tester);
  });

  testWidgets('⑦ 没上传就没有提审入口（提审是上传之后的事）', (tester) async {
    await pumpPage(tester);
    await scanAndSubmit(tester);
    expect(find.byKey(const Key('inv-submit-approval')), findsNothing,
        reason: '还没上传就给提审入口，点下去只会得到 404「盘点单不存在」');
    expect(stub.hits('POST', '/api/approval/submit'), 0);
    await drain(tester);
  });

  testWidgets('⑧ 重复提审 409 already_pending：文案转「已提交审批」而不是报错',
      (tester) async {
    await pumpPage(tester);
    final no = await scanAndSubmit(tester);
    stubUpload(no, (c) => okUpload());
    await doUpload(tester, no);

    stub.on(
        'POST',
        '/api/approval/submit',
        (c) => const StubResponse(409, <String, dynamic>{
              'error': '这个对象已经有一条待审批了',
              'code': 'already_pending',
              'id': 9,
            }));

    await waitSnackClear(tester);
    await tester.tap(find.byKey(const Key('inv-submit-approval')));
    await settleAnim(tester);
    await tapInDialog(tester, '提交');

    await waitFor(
        tester, () => find.textContaining('已经在审批中').evaluate().isNotEmpty,
        why: '"已经有一条待审"是**正常结果**，不该报成失败');
    expect(find.text('已提交审批'), findsOneWidget);
    await drain(tester);
  });
}

/// 造一份最小现场：一个点位、一个货架位、两个商品（6901 已绑 A01）。
/// 造一份最小现场：一个点位、一个货架位、两个商品（6901 已绑 A01）。
Future<void> _seed() async {
  await LocalDb.I.resetForTest();
  final db = await LocalDb.I.db();
  await db.insert('stocktake_zone', <String, Object?>{
    'zone_code': 'Z01',
    'zone_name': '生鲜区',
    'locked': 0,
    'created_at': 1,
  });
  await db.insert('location', <String, Object?>{
    'loc_code': 'A01',
    'loc_name': 'A01',
    'zone_code': 'Z01',
    'sort_no': 0,
    'created_at': 1,
  });
  for (final m in <Map<String, Object?>>[
    <String, Object?>{
      'barcode': '6901',
      'name': '矿泉水',
      'spec': '550ml',
      'unit': '瓶',
      'unit_price': 5.0,
      'account_qty': 10.0,
    },
    <String, Object?>{
      'barcode': '6902',
      'name': '方便面',
      'spec': '袋',
      'unit': '袋',
      'unit_price': 3.0,
      'account_qty': 8.0,
    },
  ]) {
    await db.insert('stock_master', <String, Object?>{
      ...m,
      'source': 'tiger',
      'updated_at': 1,
    });
  }
  await db.insert('barcode_location', <String, Object?>{
    'barcode': '6901',
    'loc_code': 'A01',
    'bound_at': 1,
  });
}
