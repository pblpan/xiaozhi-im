import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../api.dart';
import 'toledo_plu.dart';

/// 一个导出格式的定义（注册表里的一行）。
class ExportFormatDef {
  final String id;
  final String name;
  final String desc;
  final String ext; // 扩展名（不含点）

  const ExportFormatDef({
    required this.id,
    required this.name,
    required this.desc,
    required this.ext,
  });
}

/// 导出格式注册表。
///
/// ── 为什么要有注册表而不是到处 if-else ──────────────────────────
/// 龙哥 2026-10-22 需求④："按照托利多的格式导出，表格导出等方式"。
/// 各家门店的下游系统不一样（电子秤走托利多、盘点软件走通用 CSV、
/// 扫码枪走空格分隔的 txt），而且以后还会变。把格式收进一张表，
/// 加格式 = 加一行 + 一个生成分支，不在每个导出点各写一遍。
///
/// 🔴 纪律（同 app_params.dart）：只登记**真的有代码生成**的格式。
///    摆一个"支持 X"但导出内容为空/错，比没有这个选项更糟。
class ExportFormats {
  ExportFormats._();

  static const String csvGeneric = 'csv_generic';
  static const String scanDoc = 'scan_doc';
  static const String toledoPlu = 'toledo_plu';
  static const String toledoTxt = 'toledo_txt';

  static const List<ExportFormatDef> all = <ExportFormatDef>[
    ExportFormatDef(
      id: csvGeneric,
      name: '通用 CSV',
      desc: '盈亏/明细表格，Excel 双击直接打开',
      ext: 'csv',
    ),
    ExportFormatDef(
      id: scanDoc,
      name: '扫码文本文档',
      desc: '「条码 数量 商品名」空格分隔，扫码枪/盘点软件导入用',
      ext: 'txt',
    ),
    ExportFormatDef(
      id: toledoPlu,
      name: '托利多 PLU',
      desc: 'SPCT「文件 → 打开」直接导入电子秤（GBK 编码）',
      ext: 'plu',
    ),
    ExportFormatDef(
      id: toledoTxt,
      name: '托利多 TXT',
      desc: 'RL00 标准文本，走 SPCT 的 TXT→PLU 转换向导',
      ext: 'txt',
    ),
  ];

  static ExportFormatDef? byId(String id) {
    for (final f in all) {
      if (f.id == id) return f;
    }
    return null;
  }

  /// 某模块可用的格式。
  ///
  /// 托利多两个格式要**单价**（RL00 必有字段）——只有带商档价格的
  /// 扫码枪适用。简易盘点/减货/补货扫出来的是数量，没有价格，
  /// 导出托利多会得到一片 0 价记录，导进秤也是废数据，所以不给选。
  static List<ExportFormatDef> forModule(String module) {
    if (module == 'stocktake') return all;
    return const <ExportFormatDef>[
      ExportFormatDef(
        id: csvGeneric,
        name: '通用 CSV',
        desc: '明细表格，Excel 双击直接打开',
        ext: 'csv',
      ),
    ];
  }

  static String nameOf(String id) => byId(id)?.name ?? id;
}

/// 导出格式设定（与服务端 exportfmt.js 同构：moduleFormats + toledo）。
class ExportSettings {
  final Map<String, String> moduleFormats; // module id → format id
  final ToledoParams toledo;

  const ExportSettings({
    this.moduleFormats = const <String, String>{},
    this.toledo = ToledoParams.defaults,
  });

  static const ExportSettings defaults = ExportSettings();

  factory ExportSettings.fromJson(Map<String, dynamic>? j) {
    if (j == null) return defaults;
    final mf = <String, String>{};
    final rawMf = j['moduleFormats'];
    if (rawMf is Map) {
      for (final e in rawMf.entries) {
        final k = e.key.toString();
        final v = e.value?.toString() ?? '';
        if (k.isNotEmpty && v.isNotEmpty) mf[k] = v;
      }
    }
    final tj = j['toledo'];
    return ExportSettings(
      moduleFormats: mf,
      toledo: tj is Map
          ? ToledoParams.fromJson(Map<String, dynamic>.from(tj))
          : ToledoParams.defaults,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'moduleFormats': moduleFormats,
        'toledo': toledo.toJson(),
      };

  /// 某模块的默认格式。配了但注册表里没有（旧配置/手改库）→ 回落通用 CSV。
  String formatOf(String module) {
    final id = moduleFormats[module];
    if (id == null) return ExportFormats.csvGeneric;
    final ok = ExportFormats.forModule(module).any((f) => f.id == id);
    return ok ? id : ExportFormats.csvGeneric;
  }

  ExportSettings copyWith({
    Map<String, String>? moduleFormats,
    ToledoParams? toledo,
  }) =>
      ExportSettings(
        moduleFormats: moduleFormats ?? this.moduleFormats,
        toledo: toledo ?? this.toledo,
      );
}

/// 格式设定的存储与同步。
///
/// ── 三级读取 ──────────────────────────────────────────────────
///   ① 内存缓存（一次读全程用，导出点不能每次打服务端）；
///   ② 本机 SharedPreferences（离线/旧服务端时至少用得上一次）；
///   ③ 服务端（换设备同步 + 管理台改完即时生效的那一份）。
///
/// ── 写冲突怎么处理 ────────────────────────────────────────────
/// 保存时先写本机、再推服务端。推失败 → 置 `_dirty`，此后**不再拿
/// 服务端值覆盖本地**（否则"本机改了没存上、下次启动又被旧值冲掉"），
/// 改为在下次加载时重推本地值；推成功才清 dirty。
class ExportSettingsStore {
  ExportSettingsStore._();

  static const String _kKey = 'xz_export_settings_v1';

  static ExportSettings _cache = ExportSettings.defaults;
  static bool _loaded = false;
  static bool _dirty = false;

  static ExportSettings get current => _cache;
  static bool get dirty => _dirty;

  /// 读。首次会顺带打一次服务端（后台，不阻塞返回）。
  static Future<ExportSettings> load({bool forceServer = false}) async {
    if (!_loaded || forceServer) {
      try {
        final prefs = await SharedPreferences.getInstance();
        final raw = prefs.getString(_kKey);
        if (raw != null && raw.isNotEmpty) {
          _cache = ExportSettings.fromJson(
              jsonDecode(raw) as Map<String, dynamic>?);
        }
      } catch (_) {
        // 本机存储坏了/旧格式：用默认值，不值得为它弹错
      }
      _loaded = true;
      syncWithServer();
    }
    return _cache;
  }

  /// 与服务端对一次。dirty（本机有没推上去的改动）时**推**，否则**拉**。
  static Future<void> syncWithServer() async {
    if (_dirty) {
      final ok = await _push(_cache);
      if (ok) _dirty = false;
      return;
    }
    try {
      final res = await ImApi().exportSettings();
      final s = ExportSettings.fromJson(res);
      _cache = s;
      await _persist(s);
    } catch (_) {
      // 离线 / 未登录 / 旧服务端：保持本地值。导出照样能跑。
    }
  }

  /// 保存（格式设定页调用）。返回是否同步到了服务端。
  static Future<bool> save(ExportSettings s) async {
    _cache = s;
    await _persist(s);
    final ok = await _push(s);
    _dirty = !ok;
    return ok;
  }

  static Future<bool> _push(ExportSettings s) async {
    try {
      await ImApi().saveExportSettings(s.toJson());
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> _persist(ExportSettings s) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kKey, jsonEncode(s.toJson()));
    } catch (_) {
      // 存储失败只是下次启动没有缓存，不拦保存
    }
  }

  /// 测试用：直接指定（不起服务端）。
  static void debugSet(ExportSettings s) {
    _cache = s;
    _loaded = true;
    _dirty = false;
  }
}
