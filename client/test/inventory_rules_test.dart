import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/inventory_rules.dart';

/// 盘点纯规则层的测试。
///
/// 这里**不碰数据库、不碰界面** —— 所以每条判定分支都能被点名。
/// 仓库层和界面层只负责"把正确的参数喂进来"，判定本身的对错在这里定。
void main() {
  // ============================================================
  group('阶段定义', () {
    test('label 只认 1/2/3，非法值不许显示成"阶段0"', () {
      expect(InvPhase.label(1), '初盘');
      expect(InvPhase.label(2), '复盘');
      expect(InvPhase.label(3), '抽盘');
      expect(InvPhase.isValid(0), isFalse, reason: '阶段 0 是非法值');
      expect(InvPhase.isValid(4), isFalse);
      expect(InvPhase.isValid(1), isTrue);
      expect(InvPhase.isValid(2), isTrue);
      expect(InvPhase.isValid(3), isTrue);
    });

    test('prev / next 边界：初盘没有上一阶段，抽盘没有下一阶段', () {
      expect(InvPhase.prev(1), isNull);
      expect(InvPhase.prev(2), 1);
      expect(InvPhase.prev(3), 2);
      expect(InvPhase.next(1), 2);
      expect(InvPhase.next(2), 3);
      expect(InvPhase.next(3), isNull);
    });

    test('只有抽盘要求"只能扫上一阶段差异集"', () {
      expect(InvPhase.requiresDiffSetOnly(1), isFalse, reason: '初盘是全量扫');
      // 🔴 复盘**不**限差异集：复盘的价值就在于不知道哪里会错，
      //    先按差异集限制它，等于默认初盘是对的，复盘就成了走过场。
      expect(InvPhase.requiresDiffSetOnly(2), isFalse,
          reason: '复盘限定在差异集内 = 默认初盘是对的，复盘就没意义了');
      // 抽盘才是"只复核有问题的那些"：数量对不上、或者上一轮根本没扫到的。
      expect(InvPhase.requiresDiffSetOnly(3), isTrue);
    });
  });

  // ============================================================
  group('扫码准入判定 decide()', () {
    ScanDecision call({
      int phase = 1,
      String barcode = '6901',
      String zoneCode = 'Z01',
      bool sheetEditable = true,
      bool alreadyInSheet = false,
      int currentRows = 0,
      Set<String> boundZones = const <String>{'Z01'},
      Set<String> diffBarcodes = const <String>{},
      int maxRows = 500,
    }) =>
        InventoryRules.decide(
          phase: phase,
          barcode: barcode,
          zoneCode: zoneCode,
          sheetEditable: sheetEditable,
          alreadyInSheet: alreadyInSheet,
          currentRows: currentRows,
          boundZones: boundZones,
          diffBarcodes: diffBarcodes,
          maxRows: maxRows,
        );

    test('正常入账：条码绑在本点位', () {
      final d = call();
      expect(d.verdict, ScanVerdict.ok);
      expect(d.accepted, isTrue);
      expect(d.message, isNull);
    });

    test('没绑过任何货架位 → 放行但提醒（不是拒绝）', () {
      final d = call(boundZones: const <String>{});
      expect(d.verdict, ScanVerdict.okUnbound);
      expect(d.accepted, isTrue,
          reason: '上线第一天不可能有全店货架位档案，没绑就拒会让盘点没法用');
      expect(d.message, isNotNull, reason: '放行但必须让员工看见"这商品没绑货架位"');
    });

    test('绑在别的盘点位 → 拒绝，且文案就是方案里的那句', () {
      final d = call(boundZones: const <String>{'Z02'});
      expect(d.verdict, ScanVerdict.otherZone);
      expect(d.accepted, isFalse);
      expect(d.message, '当前盘点位不包含该商品');
    });

    test('一品多位：条码同时绑 Z01 和 Z02，在 Z01 盘必须放行', () {
      final d = call(boundZones: const <String>{'Z02', 'Z01'});
      expect(d.verdict, ScanVerdict.ok,
          reason: 'contains 写成了 equals/首位比较，一品多位会被误拒');
    });

    test('单据已提交 → 一律拒绝（提交后不能事后改数）', () {
      expect(call(sheetEditable: false).verdict, ScanVerdict.sheetLocked);
      expect(call(sheetEditable: false).accepted, isFalse);
    });

    test('已提交的拒绝优先于其他一切判定', () {
      // 同时满足"上限到了""不在差异集""别的点位"，
      // 但单据锁着就只该报锁定 —— 否则员工会去改一个改不动的东西。
      final d = call(
        phase: 2,
        sheetEditable: false,
        currentRows: 999,
        diffBarcodes: const <String>{},
        boundZones: const <String>{'Z99'},
      );
      expect(d.verdict, ScanVerdict.sheetLocked);
    });

    test('达到条数上限 → 拒绝，文案对齐"请提交后继续盘点！"', () {
      final d = call(currentRows: 500);
      expect(d.verdict, ScanVerdict.phaseLimit);
      expect(d.message, contains('提交'));
    });

    test('差一条到上限仍放行、正好到上限才拦（边界不能差一）', () {
      expect(call(currentRows: 499).verdict, ScanVerdict.ok);
      expect(call(currentRows: 500).verdict, ScanVerdict.phaseLimit);
      expect(call(currentRows: 501).verdict, ScanVerdict.phaseLimit);
    });

    test('已在单里的条码累加不受上限限制', () {
      // 第 500 个商品的第二件：alreadyInSheet=true 就该放行。
      // 拦住的话员工会看到"已达上限"，但他只是给同一个商品加了 1 件，完全懵。
      final d = call(currentRows: 500, alreadyInSheet: true);
      expect(d.verdict, ScanVerdict.ok);
    });

    test('复盘：不在差异集里的商品**照样放行**（复盘就是重扫一遍）', () {
      final d = call(
        phase: 2,
        barcode: '6901',
        diffBarcodes: const <String>{'6902', '6903'},
      );
      expect(d.verdict, ScanVerdict.ok,
          reason: '复盘限差异集 = 默认初盘是对的，复盘就成了走过场');
      expect(d.accepted, isTrue);
    });

    test('复盘：在差异集里的商品放行', () {
      final d = call(phase: 2, barcode: '6902', diffBarcodes: const <String>{'6902'});
      expect(d.verdict, ScanVerdict.ok);
    });

    test('抽盘：不在差异集里的商品被拒', () {
      final d = call(
        phase: 3,
        barcode: '6901',
        diffBarcodes: const <String>{'6902', '6903'},
      );
      expect(d.verdict, ScanVerdict.notInDiffSet);
      expect(d.accepted, isFalse);
      expect(d.message, contains('差异'));
    });

    test('抽盘：在差异集里的商品放行', () {
      final d = call(phase: 3, barcode: '6902', diffBarcodes: const <String>{'6902'});
      expect(d.verdict, ScanVerdict.ok);
    });

    test('未知条码（商档里没有）在初盘放行 —— 它必须进差异集', () {
      // boundZones 空 = 没绑过货架位，一般也正是"商档里没有的新品/错码"。
      expect(call(barcode: '0000NEW', boundZones: const <String>{}).accepted, isTrue);
    });

    test('反向：任何被拒的判定都不能是 accepted', () {
      final rejected = <ScanDecision>[
        call(sheetEditable: false),
        call(currentRows: 500),
        call(phase: 3, diffBarcodes: const <String>{}),   // 抽盘才限差异集
        call(boundZones: const <String>{'Z99'}),
      ];
      for (final d in rejected) {
        expect(d.accepted, isFalse, reason: '${d.verdict} 被判成可入账了');
        expect(d.message, isNotNull, reason: '${d.verdict} 被拒却没给员工一句话');
      }
    });
  });

  // ============================================================
  group('差异判定（比上一阶段，不比账面）', () {
    // 🔴 基准换过一次（2026-09-19）：门店系统里根本没有可用的库存账面
    //    （泰格库所有库存表都是空表），比账面会得到"差异集 = 全部商品"，
    //    三遍制退化成把同一个货架扫三遍。现在比的是**相邻两阶段的实盘数**。
    test('和上一阶段数量对不上才是差异', () {
      expect(InventoryRules.isDiffRow({'prev_qty': 10.0, 'diff_qty': 3.0}), isTrue);
      expect(InventoryRules.isDiffRow({'prev_qty': 10.0, 'diff_qty': -2.0}), isTrue);
      expect(InventoryRules.isDiffRow({'prev_qty': 10.0, 'diff_qty': 0.0}), isFalse);
      expect(InventoryRules.isDiffRow({'prev_qty': 10.0, 'diff_qty': 0}), isFalse,
          reason: 'SQLite 的 0 有时回 int，不能只认 double');
    });

    test('🔴 没有上一阶段可比（prev_qty 为 null）→ 不算差异', () {
      // 这条写反了后果很严重：初盘自己就会变成一个等于全部商品的差异集，
      // 后面的复盘/抽盘被它一起带偏，三遍制当场失效。
      expect(InventoryRules.isDiffRow({'prev_qty': null, 'diff_qty': null}), isFalse);
      expect(InventoryRules.isDiffRow(<String, dynamic>{}), isFalse);
    });

    test('🔴 漏盘（上一轮有、这一轮没扫）必须并进差异集', () {
      // 关键：漏盘的条码在**本阶段的行集里根本不存在**，只靠逐行谓词
      // （isDiffRow）是永远挑不出来的 —— 一定要把上一阶段的行喂进来。
      // 曾经 diffBarcodesOf 收了 prevRows 却没并 missingVsPrev，
      // 结果差异集少算漏盘：数量错了至少还显眼，"少一行"是看不出来的。
      final rows = InventoryRules.attachPrevDiff(
        [
          {'barcode': '6901', 'qty': 12.0}, // 与上一轮一致
          {'barcode': '6902', 'qty': 9.0}, // 8 → 9，对不上
        ],
        const <String, double>{'6901': 12.0, '6902': 8.0, '6903': 5.0},
      );
      expect(InventoryRules.diffBarcodesOf(rows), <String>{'6902'},
          reason: '只给本阶段的行时，6903 这种漏盘看不见（这是逐行谓词的天花板）');

      final withPrev = InventoryRules.diffBarcodesOf(
        rows,
        prevRows: const <Map<String, dynamic>>[
          {'barcode': '6901', 'qty': 12.0},
          {'barcode': '6902', 'qty': 8.0},
          {'barcode': '6903', 'qty': 5.0},
        ],
      );
      expect(withPrev, <String>{'6902', '6903'},
          reason: '喂了上一阶段的行，漏盘 6903 才算得进来');
    });

    test('isDiffRow 是逐行谓词：没有参照值一律不算差异', () {
      expect(InventoryRules.isDiffRow(<String, dynamic>{}), isFalse);
      expect(InventoryRules.isDiffRow({'prev_qty': null, 'diff_qty': null}), isFalse);
      // 只给了参照值没给差值（手工构造行）→ 按"对不上"处理
      expect(InventoryRules.isDiffRow({'prev_qty': 10.0}), isTrue);
    });

    test('attachPrevDiff 补出来的 diff_qty 是本阶段减上一阶段', () {
      final rows = InventoryRules.attachPrevDiff(
        [
          {'barcode': '6901', 'qty': 15.0},
          {'barcode': '6902', 'qty': 10.0},
          {'barcode': '6903', 'qty': 7.0},   // 上一轮没盘过
        ],
        const <String, double>{'6901': 12.0, '6902': 10.0},
      );
      expect(rows[0]['diff_qty'], 3.0);
      expect(rows[1]['diff_qty'], 0.0);
      expect(rows[2]['prev_qty'], isNull);   // 没有上一阶段可比
      expect(rows[2]['diff_qty'], isNull);
    });

    test('missingVsPrev 能捞出上一轮盘过、这一轮没扫的（漏盘）', () {
      final miss = InventoryRules.missingVsPrev(
        [
          {'barcode': '6901', 'qty': 12.0},
          {'barcode': '6902', 'qty': 10.0},
        ],
        [
          {'barcode': '6901', 'qty': 12.0},
        ],
      );
      expect(miss, <String>{'6902'},
          reason: '漏盘在明细里根本看不出来，抽盘必须把它捞出来');
    });

    test('diffBarcodesOf 跳过空条码，不把空串塞进差异集', () {
      final set = InventoryRules.diffBarcodesOf(InventoryRules.attachPrevDiff(
        [
          {'barcode': '6901', 'qty': 11.0},
          {'barcode': '', 'qty': 5.0},
          {'barcode': '   ', 'qty': 5.0},
          {'barcode': '6902', 'qty': 10.0},
        ],
        const <String, double>{'6901': 10.0, '6902': 10.0},
      ));
      expect(set, <String>{'6901'});
    });
  });

  // ============================================================
  group('失误笔数', () {
    test('两阶段都有、数量不同 → 算 1 笔', () {
      final n = InventoryRules.mistakeCount(
        [
          {'barcode': '6901', 'qty': 10.0},
          {'barcode': '6902', 'qty': 5.0},
        ],
        [
          {'barcode': '6901', 'qty': 12.0},
          {'barcode': '6902', 'qty': 5.0},
        ],
      );
      expect(n, 1);
    });

    test('数量相同不算失误', () {
      final n = InventoryRules.mistakeCount(
        [
          {'barcode': '6901', 'qty': 10.0}
        ],
        [
          {'barcode': '6901', 'qty': 10.0}
        ],
      );
      expect(n, 0);
    });

    test('本阶段没再扫这条 → 不算失误（那是"差异未复核"，另一栏）', () {
      // 混进失误笔数会让这个数虚高，主管拿它考核人就不公平了。
      final n = InventoryRules.mistakeCount(
        [
          {'barcode': '6901', 'qty': 10.0},
          {'barcode': '6902', 'qty': 5.0},
        ],
        [
          {'barcode': '6901', 'qty': 10.0}
        ],
      );
      expect(n, 0, reason: '复盘没扫的商品被算成失误了');
    });

    test('本阶段新扫出来的 → 不算失误', () {
      final n = InventoryRules.mistakeCount(
        [
          {'barcode': '6901', 'qty': 10.0}
        ],
        [
          {'barcode': '6901', 'qty': 10.0},
          {'barcode': '6909', 'qty': 3.0},
        ],
      );
      expect(n, 0);
    });

    test('int/double 混着来也算相等（SQLite 的 REAL 有时回 int）', () {
      final n = InventoryRules.mistakeCount(
        [
          {'barcode': '6901', 'qty': 10}
        ],
        [
          {'barcode': '6901', 'qty': 10.0}
        ],
      );
      expect(n, 0, reason: '10 和 10.0 被判成不同数量，失误笔数凭空多一笔');
    });

    test('空集合不炸', () {
      expect(InventoryRules.mistakeCount(const [], const []), 0);
    });
  });
}
