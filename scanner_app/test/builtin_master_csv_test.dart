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
  test('统一商档（管理台 7 列）能完整解析出字段', () {
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
    final bytes = f.readAsBytes();
    // Gbk.decodeSmart 会自动处理 UTF-8 BOM —— 这份就是 BOM + UTF-8。
    final text = Gbk.decodeSmart(bytes);
    final r = MasterCsv.parse(text);

    // 数量级：管理台显示 126793 条
    print('解析到 ${r.items.length} 条 / 读入 ${r.total} 行 / 跳过 ${r.skipped}');
    expect(r.items.length, greaterThan(120000));

    // 🔴 关键：字段**真的在**。取值来自管理台线上库的真实样例。
    Map<String, dynamic>? find(String bc) {
      for (final it in r.items) {
        if (it['barcode'].toString() == bc) return it;
      }
      return null;
    }

    final candy = find('10');
    expect(candy, isNotNull, reason: '条码 10 应存在');
    print('条码10 → ${candy}');
    expect(candy!['name'].toString(), '椰丝软糖[芒果]');
    // 这三列就是"静默丢失"高发区，必须逐个钉住具体值
    expect(candy['spec'].toString(), '500g');
    expect(candy['unit'].toString(), '公斤');
    expect(candy['unit_price'].toString(), '19.6');
    expect(candy['account_qty'].toString(), '1');

    final mantou = find('100');
    expect(mantou, isNotNull);
    expect(mantou!['name'].toString(), '馒头');
    expect(mantou['spec'].toString(), '袋');
    expect(mantou['unit'].toString(), '袋');
    expect(mantou['unit_price'].toString(), '2');

    // 13 位真实条码（截图里有 1000008800209）
    final long = find('1000008800209');
    expect(long, isNotNull, reason: '13 位条码应存在');
    expect(long!['name'].toString(), '韩国每日鲜牛奶200ml*24');
    expect(long['spec'].toString(), '200ml*24');
    expect(long['unit'].toString(), '箱');

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
