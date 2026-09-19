import 'dart:io';

import 'package:flutter/services.dart';

import 'gbk.dart';
import 'local_db.dart';
import 'stock_master_repo.dart';

/// APK 里**自带**的那份商品档案（好又多版才有）。
///
/// ── 为什么要有这条路 ──────────────────────────────────────────
/// 通用版让员工自己导一份 CSV。但门店的商品主档本来就在系统里（12.7 万条），
/// 让员工去"找一份表、传进手机、再导入"，每一步都会掉人；
/// 真到盘点那天，一半人手机里还是空的，扫什么都是"未知条码"。
/// 所以给固定门店出的版本直接**把档案打进 APK**：装完就能扫。
///
/// ── 为什么文件不放在 pubspec 的 assets ────────────────────────
/// 那份会被打进 flutter_assets，**两个版本都带上** —— 通用版平白胖 6.6MB，
/// 还带着别人的商品数据。放在 android 的 flavor 资产目录里就只属于这一版。
/// 代价：Dart 的 rootBundle 读不到它（只认 flutter_assets），
/// 得让原生把它拷到内部存储、把路径给 Dart（见 MainActivity 的 builtinMaster）。
class BuiltinMaster {
  /// 与 MainActivity 的 CHANNEL 必须逐字一致。
  static const MethodChannel _ch = MethodChannel('xiaozhi/share');

  /// 这个包带不带内置档案 —— **问原生**：APK 里有没有那份 asset。
  ///
  /// ── 为什么不用 `--dart-define=BRAND=hyd` ──────────────────────
  /// 第一版就是那么写的，然后发现两个坑：
  ///  ① 漏传 dart-define 时 gradle 全程不报错、档案也确实在包里，
  ///     但 App 运行时认为"没有" —— 装完了没有内置档案也没有恢复入口，
  ///     只能等员工打回票才发现。构建参数这种"记住要传"的东西迟早会漏。
  ///  ② 想在产物里留个标记来查？留不住。常量被折叠后连标记本身都被
  ///     tree-shake 摇掉了（实测：包里既搜不到 'BRAND=hyd' 也搜不到 'BRAND='）。
  /// 所以改成运行时问原生：APK 里有这份 asset 就是有，没有就是没有。
  /// 判据和实施是同一件事，不可能不同步。
  ///
  /// 返回值会被调用方缓存（见 StocktakePage），不用每次都问。
  static Future<bool> hasBuiltin() async => (await path()) != null;

  /// 内置档案在内部存储里的路径；没有则 null。
  static Future<String?> path() async {
    try {
      return await _ch.invokeMethod<String>('builtinMaster');
    } on MissingPluginException {
      return null;
    }
  }

  /// 把内置档案装进本地底表。
  ///
  /// [clearFirst] = 真时先清空现有档案（"恢复内置"用：员工之前自己导过一份，
  /// 那份可能不全，恢复内置就是回到出厂那份全的）。
  ///
  /// [onProgress] 会给 (已完成, 总数)。**12.7 万条没有进度就等于卡死**：
  /// 员工看到十几秒没反应，第一反应是卸载重装。
  static Future<MasterImportResult> load({
    required bool clearFirst,
    void Function(int done, int total)? onProgress,
  }) async {
    final p = await path();
    if (p == null) {
      throw const FormatException('这个版本没有内置商品档案，请用「导入商档 CSV」');
    }
    final bytes = await File(p).readAsBytes();
    final parsed = MasterCsv.parse(Gbk.decodeSmart(bytes));
    if (parsed.items.isEmpty) {
      throw const FormatException('内置商品档案是空的（安装包可能不完整），请重新安装');
    }

    final db = await LocalDb.I.db();
    if (clearFirst) {
      // 整表清掉再写。这里**不走** upsertAll 的 purgeMissing：
      // 那是用 `barcode NOT IN (12.7万个?)` 实现的，SQLite 扛不住这个参数量。
      await db.delete('stock_master',
          where: 'source = ?', whereArgs: <Object?>[StockMasterRepo.sourceTag]);
    }
    final n = await StockMasterRepo.upsertAll(
      db,
      parsed.items,
      purgeMissing: false,
      onProgress: onProgress,
    );
    return MasterImportResult(
      written: n,
      skipped: parsed.skipped,
      total: parsed.total,
    );
  }
}
