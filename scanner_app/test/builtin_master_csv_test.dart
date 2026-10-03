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
  test('统一商档（管理台 7 列）能完整解析出字段', () async {
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
    // Gbk.decodeSmart 会自动处理 UTF-8 BOM —— 这份就是 BOM + UTF-8。
    final text = Gbk.decodeSmart(bytes);
    final r = MasterCsv.parse(text);

    // 数量级：管理台显示 126793 条
    print('读入 ${r.total} 行 / 解析到 ${r.items.length} 条 / 跳过 ${r.skipped}');
    expect(r.items.length, greaterThan(120000));

    // 🔴 关键：字段**真的在**。取值来自管理台线上库的真实样例。
    //    先建索引再查 —— 12.6 万条线性扫 3 次是 40 万次比较，测着慢；
    //    顺带保证拿到的是"最后一条同码"，与 SQLite upsert 的语义一致。
    final byCode = <String, Map<String, dynamic>>{};
    for (final it in r.items) {
      byCode[it['barcode'].toString()] = it;
    }
    Map<String, dynamic>? find(String bc) => byCode[bc];

    // 🔴 售价/进价是 **REAL**：SQLite 给 `2.0`、不是 `2`。
    //    一律用**数值**比较（`double.tryParse`），别比字符串 ——
    //    比字符串就得写死 '2' 还是 '2.0'，那是数据库驱动的表示细节、换平台就变。
    //    2026-10-03 CI 第一次就死在这：Expected: '2'  Actual: '2.0'
    double? priceOf(Map<String, dynamic>? m) =>
        m == null ? null : double.tryParse(m['unit_price'].toString());
    double? qtyOf(Map<String, dynamic>? m) =>
        m == null ? null : double.tryParse(m['account_qty'].toString());

    final candy = find('10');
    expect(candy, isNotNull, reason: '条码 10 应存在');
    print('条码10 → $candy');
    expect(candy!['name'].toString(), '椰丝软糖[芒果]');
    // 这三列就是"静默丢失"高发区，必须逐个钉住具体值
    expect(candy['spec'].toString(), '500g');
    expect(candy['unit'].toString(), '公斤');
    expect(priceOf(candy), 19.6);
    // 🔴 数量（账面数）**故意不断言具体值**：它是库存、随盘点变。
    //    换档时这条最容易变成"测试红了但代码没错"，那就白折腾。
    //    这里只断言它"有值"（证明这一列确实被解析到了）。
    expect(qtyOf(candy), isNotNull);

    final mantou = find('100');
    expect(mantou, isNotNull);
    expect(mantou!['name'].toString(), '馒头');
    expect(mantou['spec'].toString(), '袋');
    expect(mantou['unit'].toString(), '袋');
    expect(priceOf(mantou), 2.0);

    // 🔴 样本必须取自**真实档案**，别照着截图抄。
    //    实测踩过：截图里那几行「韩国每日鲜牛奶200ml*24」是管理台的**演示数据**，
    //    真实商档里一条都没有（grep 0 命中）—— 照抄就会写出一条
    //    "条码 1000008800209 不存在"的假断言，红了还得回头查是不是代码坏了。
    //    现在用的是真存在、且规格/单位/进价三列都有值的商品。
    final real = find('1234567890104');
    expect(real, isNotNull, reason: '13 位真实条码应存在');
    expect(real!['name'].toString(), '积木K313');
    expect(real['spec'].toString(), 'K313');
    expect(real['unit'].toString(), '包');
    expect(priceOf(real), 29.0);
    // 长条码最关键：它是最容易在 Excel 里被变成科学计数法、也最容易在
    // 解析时被截断的一类（见 skill gradle-assets-silent-drop 里的条码保护）。
    expect(real['barcode'].toString().length, 13);

    // 字段覆盖率统计：spec/unit 只该有部分商品有，不能是 0。
    int withSpec = 0, withUnit = 0, withPrice = 0;
    for (final it in r.items) {
      if ((it['spec']?.toString() ?? '').isNotEmpty) withSpec++;
      if ((it['unit']?.toString() ?? '').isNotEmpty) withUnit++;
      if ((it['unit_price']?.toString() ?? '').isNotEmpty) withPrice++;
    }
    print('字段覆盖：spec=$withSpec unit=$withUnit price=$withPrice');
    // 线上库实测：规格 123040 / 单位 121344 / 售价 126793
    expect(withSpec, greaterThan(100000));
    expect(withUnit, greaterThan(100000));
    expect(withPrice, r.items.length);
  });
}
