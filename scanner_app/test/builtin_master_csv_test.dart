// 实测：这份统一商档 CSV 喂给扫码枪的 MasterCsv 解析器，字段会不会掉。
//
// 🔴 为什么必须实测而不是"看着能解析"
//   截图顶部那段红字警告过：导入显示成功、不报错，三个月后才发现规格/单位全丢。
//   解析器认不认某列 → 认不出就**静默丢弃**，界面照样报"导入成功"。
//   这是"坏了也不报错"的典型，只能靠打印真实解析结果来发现。
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_scanner/core/gbk.dart';
import 'package:xiaozhi_scanner/core/stock_master_repo.dart';

void main() {
  test('统一商档（10 列，2026-10-12 换档）能完整解析出字段', () async {
    const p = 'android/app/src/hyd/assets/builtin_master.csv';
    final f = File(p);
    // 🔴 这份 CSV 被 .gitignore 排除（门店数据不入库），**CI runner 上没有它** ——
    //    它是构建 job 从 release 附件（tag hyd-master-data）下载再打进 APK 的。
    //    所以这里必须在缺文件时**跳过**（markTestSkipped）而不是失败：
    //    否则每次 CI 都会红，而红的原因跟代码毫无关系。
    //    真正的把关在两处：① 构建 job 下载后校验 sha256 + 行数量级；
    //                     ② 打完包解包断言这个文件在 APK 里且体积够。
    //    换商档后想让本机也真跑一遍：跑一次 _ci_hyd_master.py（它会落地本地文件）。
    if (!f.existsSync()) {
      markTestSkipped('本机没有内置商档（gitignore 的门店数据）；'
          'CI 侧把关见 build.yml 的 build-scanner-hyd job');
      return;
    }
    // 🔴 `readAsBytes()` 是**异步**的（返回 Future<Uint8List>），
    //    而 `Gbk.decodeSmart(List<int>)` 要同步字节 —— 必须 await，
    //    漏了就是 `Future<Uint8List> can't be assigned to List<int>`
    //    （2026-10-03 CI 第一次就死在这行；本机类型检查对 scanner_app 不可用，
    //     所以只能靠 CI 抓 —— 见 skill dart-inprocess-analyzer-typecheck 坑 15）。
    final bytes = await f.readAsBytes();
    // 新档是 GBK 编码 —— Gbk.decodeSmart 自适应。
    final text = Gbk.decodeSmart(bytes);
    final r = MasterCsv.parse(text);

    // 数量级：2026-10-12 换的新档 126913 条
    //（桌面《商品信息-带表头.csv》直导，10 列：条码,商品名称,规格,单位,进价,售价,会员价,特价,库存,供应商名称）
    print('读入 ${r.total} 行 / 解析到 ${r.items.length} 条 / 跳过 ${r.skipped}');
    expect(r.items.length, greaterThan(120000));

    // 🔴 关键：字段**真的在**。取值来自新商档 CSV 的真实行（2026-10-12 实取）。
    //    先建索引再查 —— 12.6 万条线性扫多次很慢；顺带保证拿到的是
    //    "最后一条同码"，与 SQLite upsert 的语义一致。
    final byCode = <String, Map<String, dynamic>>{};
    for (final it in r.items) {
      byCode[it['barcode'].toString()] = it;
    }
    Map<String, dynamic>? find(String bc) => byCode[bc];

    // 🔴 价格/库存是 **REAL**：SQLite 给 `2.0`、不是 `2`。
    //    一律用**数值**比较（`double.tryParse`），别比字符串 ——
    //    比字符串就得写死 '2' 还是 '2.0'，那是数据库驱动的表示细节、换平台就变。
    double? numOf(Map<String, dynamic>? m, String k) =>
        m == null ? null : double.tryParse(m[k].toString());

    // 全列样本：进价/会员价/供应商都有值的行（v4 新列的守门样例）
    final fan = find('6975505370221');
    expect(fan, isNotNull, reason: '条码 6975505370221 应存在');
    print('饭自在 → $fan');
    expect(fan!['name'].toString(), '饭自在广式香肠自热米饭386g');
    expect(fan['spec'].toString(), '386g');
    expect(fan['unit'].toString(), '盒');
    expect(numOf(fan, 'unit_price'), 12.9);
    expect(numOf(fan, 'purchase_price'), 10.0);
    expect(numOf(fan, 'member_price'), 12.8);
    expect(fan['supplier'].toString(), '0好又多');

    // 🔴 13 位条码最关键：它是最容易在 Excel 里被变成科学计数法、也最容易在
    //    解析时被截断的一类（见 skill gradle-assets-silent-drop 里的条码保护）。
    final wine = find('6931751410074');
    expect(wine, isNotNull, reason: '13 位真实条码应存在');
    expect(wine!['name'].toString(), '蜂丹马爹利皇室红葡萄酒');
    expect(wine['spec'].toString(), '750ML');
    expect(wine['unit'].toString(), '瓶');
    expect(numOf(wine, 'unit_price'), 32.0);
    expect(numOf(wine, 'member_price'), 32.0);
    expect(wine['barcode'].toString().length, 13);

    // 店内短码（6 位，纯数字）—— 不能被误当成"序号列"跳掉
    final instore = find('992404');
    expect(instore, isNotNull, reason: '店内短码应存在');
    expect(instore!['name'].toString(), '百年好合囍帖');
    expect(instore['spec'].toString(), '20个');
    expect(instore['unit'].toString(), '捆');
    expect(numOf(instore, 'unit_price'), 18.5);
    expect(numOf(instore, 'purchase_price'), 0.0);

    // 供应商为空的行（该列允许空，界面按"没有就不显示"处理）
    final noSup = find('6920547851672');
    expect(noSup, isNotNull);
    expect(noSup!['name'].toString(), '蒂花之秀洗发露');
    expect(noSup['supplier'].toString(), '');

    // 字段覆盖率统计：不能是 0（静默丢列就是靠这个抓的）。
    int withSpec = 0, withUnit = 0, withPrice = 0, withSupplier = 0;
    for (final it in r.items) {
      if ((it['spec']?.toString() ?? '').isNotEmpty) withSpec++;
      if ((it['unit']?.toString() ?? '').isNotEmpty) withUnit++;
      if ((it['unit_price']?.toString() ?? '').isNotEmpty) withPrice++;
      if ((it['supplier']?.toString() ?? '').isNotEmpty) withSupplier++;
    }
    print('字段覆盖：spec=$withSpec unit=$withUnit price=$withPrice supplier=$withSupplier');
    // 新档实测：规格 123134 / 单位 121436 / 售价 126913（全）/ 供应商 126891
    expect(withSpec, greaterThan(100000));
    expect(withUnit, greaterThan(100000));
    expect(withPrice, r.items.length);
    expect(withSupplier, greaterThan(120000));
  });
}
