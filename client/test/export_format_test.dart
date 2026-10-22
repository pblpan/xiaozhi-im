import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/export_format.dart';

/// 导出格式注册表 + 格式设定的单测（纯 Dart，不起服务端）。
void main() {
  group('注册表', () {
    test('id 唯一、byId 查得到、查不到给 null', () {
      final ids = ExportFormats.all.map((f) => f.id).toSet();
      expect(ids.length, ExportFormats.all.length, reason: 'id 不许重复');
      expect(ExportFormats.byId('toledo_plu')?.name, '托利多 PLU');
      expect(ExportFormats.byId('不存在的格式'), isNull);
    });

    test('托利多只给有价格数据的模块选', () {
      final stocktake = ExportFormats.forModule('stocktake').map((f) => f.id).toList();
      expect(stocktake, containsAll(<String>[
        ExportFormats.csvGeneric,
        ExportFormats.scanDoc,
        ExportFormats.toledoPlu,
        ExportFormats.toledoTxt,
      ]));
      // 简易盘点只有数量没有价格 → 导出托利多会得到一片 0 价记录，不给选
      final simple = ExportFormats.forModule('simple_stocktake').map((f) => f.id).toList();
      expect(simple, <String>[ExportFormats.csvGeneric]);
    });
  });

  group('ExportSettings 解析', () {
    test('null → 默认', () {
      final s = ExportSettings.fromJson(null);
      expect(s.moduleFormats, isEmpty);
      expect(s.toledo.pluMode, 'seq');
      expect(s.formatOf('stocktake'), ExportFormats.csvGeneric);
    });

    test('moduleFormats 过滤空键空值；toledo 坏值回落', () {
      final s = ExportSettings.fromJson(<String, dynamic>{
        'moduleFormats': <String, dynamic>{
          'stocktake': 'toledo_plu',
          '': 'x',
          'deduct': '',
        },
        'toledo': <String, dynamic>{'group': 99, 'pluMode': 'magic'},
      });
      expect(s.moduleFormats, <String, String>{'stocktake': 'toledo_plu'});
      expect(s.toledo.group, 20);
      expect(s.toledo.pluMode, 'seq');
    });

    test('formatOf：配了且注册表认得 → 用它；配了不认得 → 回落通用 CSV', () {
      final s = ExportSettings.fromJson(<String, dynamic>{
        'moduleFormats': <String, dynamic>{
          'stocktake': 'toledo_txt',
          'simple_stocktake': 'toledo_plu', // 该模块没这个格式
        },
      });
      expect(s.formatOf('stocktake'), ExportFormats.toledoTxt);
      expect(s.formatOf('simple_stocktake'), ExportFormats.csvGeneric);
      expect(s.formatOf('deduct'), ExportFormats.csvGeneric);
    });

    test('toJson 不携带 variant（文件形态由格式 id 决定）', () {
      final s = ExportSettings.fromJson(<String, dynamic>{
        'moduleFormats': <String, dynamic>{'stocktake': 'toledo_plu'},
      });
      final j = s.toJson();
      expect((j['toledo'] as Map).containsKey('variant'), isFalse);
      // 全量往返
      expect(ExportSettings.fromJson(j).formatOf('stocktake'), ExportFormats.toledoPlu);
    });

    test('copyWith 局部替换', () {
      const s = ExportSettings();
      final s2 = s.copyWith(moduleFormats: <String, String>{'deduct': 'csv_generic'});
      expect(s.moduleFormats, isEmpty, reason: '原对象不被修改');
      expect(s2.moduleFormats['deduct'], 'csv_generic');
    });
  });
}
