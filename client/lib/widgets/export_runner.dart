import 'dart:io';

import 'package:flutter/material.dart';

import '../api.dart';
import '../core/export_format.dart';
import '../core/file_io.dart';
import '../core/toledo_plu.dart';
import 'export_flow.dart';

/// 一次导出的请求单。各页面把自己的数据按这个形状交进来，
/// 选格式 / 生成 / 落盘 / 记账 / 后续动作由 [ExportRunner] 统一办。
///
/// 为什么页只交数据不办流程：导出动作在扫码枪、简易盘点、减货、补货
/// 四个页面都存在，每页各写一遍"弹选择→写文件→记台账→弹后续面板"
/// 必有页面漏一步（最常见的漏的是记账）。收口到这一个类，
/// 加新导出点 = 填一张请求单。
class ExportRequest {
  /// 模块 id（台账归类用）：'stocktake' 扫码枪 / 'simple_stocktake' 简易盘点 /
  /// 'deduct' 减货 / 'replenish' 补货 / 'inventory' 盘点
  final String module;

  /// 模块中文名（台账显示 + 记录快照）
  final String moduleName;

  /// 单据号（可空）
  final String docNo;

  /// 文件名里的场景名（单据名/任务名，没有就用单号）
  final String sceneLabel;

  /// 导出行数（托利多的实际行数以排版结果为准，跳过了无效行会变少）
  final int rowCount;

  /// 通用 CSV 文本（模块现有 toCsv 的产物，BOM 已由导出层加在内容里）
  final String? csvText;
  final String? csvFileName;

  /// 扫码文本文档（toScanDoc 产物，CRLF + BOM 已内置）
  final String? docText;
  final String? docFileName;

  /// 托利多行（**只有带商档价格的模块给**；没有价格的数据导出托利多
  /// 会得到一片 0 价记录，那种格式注册表压根不该给它选，见 ExportFormats.forModule）
  final List<ToledoRow>? toledoRows;

  const ExportRequest({
    required this.module,
    required this.moduleName,
    required this.docNo,
    required this.sceneLabel,
    required this.rowCount,
    this.csvText,
    this.csvFileName,
    this.docText,
    this.docFileName,
    this.toledoRows,
  });
}

class ExportRunner {
  ExportRunner._();

  /// 跑一次导出。返回 true = 文件已落盘（后续动作面板已弹过）；
  /// false = 用户取消 / 没有可导内容 / 失败（原因已 snack）。
  static Future<bool> run(BuildContext context, ExportRequest req) async {
    final formats = ExportFormats.forModule(req.module);

    // 格式设定（内存缓存，首次会顺带后台同步服务端）
    final settings = await ExportSettingsStore.load();

    // 只有一个格式就别弹选择器 —— 摆一个单项列表是脱裤子放屁
    var picked = settings.formatOf(req.module);
    if (formats.length > 1) {
      final chosen = await _pickFormat(context, formats, picked);
      if (chosen == null || chosen.isEmpty) return false;
      picked = chosen;
      // 记住选择（就是"每个模块的默认格式"，格式设定页里也看得到它）
      if (settings.formatOf(req.module) != picked) {
        final mf = Map<String, String>.from(settings.moduleFormats);
        mf[req.module] = picked;
        // 不 await：存哪了不该让导出等；失败也只是这次没记住
        ExportSettingsStore.save(settings.copyWith(moduleFormats: mf));
      }
    }

    // ---- 生成 ----
    String? text;
    List<int>? bytes;
    String fileName;
    var rows = req.rowCount;
    var missedNames = 0;

    if (picked == ExportFormats.toledoPlu || picked == ExportFormats.toledoTxt) {
      final variant = picked == ExportFormats.toledoPlu ? 'plu' : 'txt';
      final b = ToledoPlu.build(
        req.toledoRows ?? const <ToledoRow>[],
        variant: variant,
        params: settings.toledo,
      );
      if (b.rowCount == 0) {
        _snack(context, '没有可导出的记录（商品名和条码都为空的行会被跳过）');
        return false;
      }
      bytes = b.bytes;
      rows = b.rowCount;
      missedNames = b.missedNames;
      fileName = ToledoPlu.fileName(req.sceneLabel, req.docNo, variant: variant);
    } else {
      if (picked == ExportFormats.scanDoc) {
        text = req.docText;
        fileName = req.docFileName ?? '';
      } else {
        text = req.csvText;
        fileName = req.csvFileName ?? '';
      }
      if (text == null || text.trim().isEmpty || fileName.isEmpty) {
        _snack(context, '这种格式本次没有可导出的内容');
        return false;
      }
    }

    // ---- 落盘 ----
    File f;
    try {
      final dir = await FileIo.dir();
      f = File('${dir.path}${Platform.pathSeparator}${FileIo.safeName(fileName)}');
      if (bytes != null) {
        await f.writeAsBytes(bytes); // 托利多：GBK 字节，不能走 writeAsString
      } else {
        await f.writeAsString(text!); // UTF-8；BOM 由各导出层加在内容里
      }
    } catch (e) {
      _snack(context, '导出失败：$e');
      return false;
    }

    // ---- 记账（服务端台账；失败不影响导出本身，文件已经在用户手里了）----
    ImApi()
        .reportExport(
          module: req.module,
          moduleName: req.moduleName,
          docNo: req.docNo,
          formatId: picked,
          formatName: ExportFormats.nameOf(picked),
          fileName: fileName,
          rows: rows,
          ext: ExportFormats.byId(picked)?.ext,
        )
        .catchError((_) {});

    if (missedNames > 0) {
      _snack(context, '有 $missedNames 个商品名含生僻字，导入电子秤后会显示 ?');
    }

    // ---- 后续动作（打开 / 分享 / 另存为）----
    await ExportFlow.show(
      context,
      f,
      rows: rows,
      suggestName: fileName,
      onMessage: (m) => _snack(context, m),
    );
    return true;
  }

  /// 格式选择。返回 null = 取消。
  static Future<String?> _pickFormat(
    BuildContext context,
    List<ExportFormatDef> formats,
    String current,
  ) {
    return showModalBottomSheet<String>(
      context: context,
      backgroundColor: Theme.of(context).cardColor,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                child: Row(
                  children: [
                    Text('导出格式',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w600,
                            color: Theme.of(ctx).textTheme.titleLarge?.color)),
                    const Spacer(),
                    Text('下次默认用这次选的',
                        style: TextStyle(
                            fontSize: 11,
                            color: Theme.of(ctx).textTheme.bodySmall?.color)),
                  ],
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final f in formats)
                      RadioListTile<String>(
                        value: f.id,
                        groupValue: current,
                        title: Text(f.name),
                        subtitle: Text(f.desc,
                            style: const TextStyle(fontSize: 12)),
                        onChanged: (v) => Navigator.pop(ctx, v),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  static void _snack(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }
}
