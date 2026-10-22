import 'package:flutter/material.dart';

import '../core/export_format.dart';
import '../core/theme.dart';
import '../core/toledo_plu.dart';

/// 导出格式设定页（个人中心 → 导出 → 格式设定）。
///
/// 管两件事：
///   ① 每个模块**默认**用哪种格式导出（导出时的选择器会记住上次选择，
///      本质上就是改这里；管理台/别的设备上也是同一份）；
///   ② 托利多电子秤的参数（PLU 号怎么编、组号、税号、保质期、计价方式…）。
///
/// 🔴 纪律（同 app_params.dart）：只摆**真的有代码在读**的配置。
///    这里每个开关都接到 export_format.dart / toledo_plu.dart 上；
///    看着像配置其实没人读的项，一律不放 —— 管理员改完发现没效果，
///    就再也不信这个页面上的任何东西了。
class ExportSettingsPage extends StatefulWidget {
  const ExportSettingsPage({super.key});

  @override
  State<ExportSettingsPage> createState() => _ExportSettingsPageState();
}

class _ExportSettingsPageState extends State<ExportSettingsPage> {
  late ExportSettings _s;
  bool _dirty = false;
  bool _saving = false;
  String? _note; // 保存回执（不同步成功时的提示）

  // 只列**真的接了格式体系**的模块。减货/补货/盘点采集以后接进来再补行，
  // 现在摆上来就是"配了没反应"。
  static const List<Map<String, String>> _modules = <Map<String, String>>[
    {'id': 'stocktake', 'name': '扫码枪盘点'},
    {'id': 'simple_stocktake', 'name': '简易盘点'},
  ];

  @override
  void initState() {
    super.initState();
    _s = ExportSettingsStore.current;
    ExportSettingsStore.load().then((v) {
      if (mounted) setState(() => _s = v);
    });
  }

  void _setModuleFormat(String module, String formatId) {
    final mf = Map<String, String>.from(_s.moduleFormats);
    mf[module] = formatId;
    setState(() {
      _s = _s.copyWith(moduleFormats: mf);
      _dirty = true;
    });
  }

  void _setToledo(ToledoParams p) {
    setState(() {
      _s = _s.copyWith(toledo: p);
      _dirty = true;
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final ok = await ExportSettingsStore.save(_s);
    if (!mounted) return;
    setState(() {
      _saving = false;
      _dirty = false;
      _note = ok ? null : '已存本机；没连上服务器，下次打开应用会自动同步';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bgElevated,
        title: const Text('导出格式设定', style: TextStyle(fontSize: 17)),
        actions: [
          if (_dirty)
            TextButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('保存'),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 32),
        children: [
          _section('默认导出格式', [
            for (final m in _modules)
              _moduleFormatRow(m['id']!, m['name']!),
          ]),
          const SizedBox(height: 14),
          _section('托利多电子秤参数', [
            _enumRow(
              'PLU 号来源',
              _s.toledo.pluMode,
              const {'seq': '按行序 1,2,3…', 'barcode_tail': '取条码后 6 位'},
              (v) => _setToledo(_s.toledo.copyWith(pluMode: v)),
            ),
            _enumRow(
              '计价方式',
              _s.toledo.priceMode,
              const {'auto': '按单位自动判', 'weight': '全部按计重', 'count': '全部按计数'},
              (v) => _setToledo(_s.toledo.copyWith(priceMode: v)),
            ),
            _intRow('组号', _s.toledo.group, 0, 20,
                (v) => _setToledo(_s.toledo.copyWith(group: v))),
            _intRow('皮重号', _s.toledo.tare, 0, 16,
                (v) => _setToledo(_s.toledo.copyWith(tare: v))),
            _intRow('税号', _s.toledo.tax, 0, 9,
                (v) => _setToledo(_s.toledo.copyWith(tax: v))),
            _intRow('保质期（天）', _s.toledo.shelfLife, 0, 499,
                (v) => _setToledo(_s.toledo.copyWith(shelfLife: v))),
            _intRow('推荐期（天）', _s.toledo.recommendLife, 0, 499,
                (v) => _setToledo(_s.toledo.copyWith(recommendLife: v))),
            _switchRow(
              '允许秤上改价',
              _s.toledo.allowReprice == 1,
              (v) => _setToledo(_s.toledo.copyWith(allowReprice: v ? 1 : 0)),
            ),
            _switchRow(
              '允许打折',
              _s.toledo.allowDiscount == 1,
              (v) => _setToledo(_s.toledo.copyWith(allowDiscount: v ? 1 : 0)),
            ),
          ]),
          const SizedBox(height: 14),
          _notes(),
          if (_note != null) ...[
            const SizedBox(height: 10),
            Text(_note!,
                style: TextStyle(fontSize: 12, color: AppColors.warn)),
          ],
        ],
      ),
    );
  }

  // ---------------- 零件 ----------------

  Widget _section(String title, List<Widget> children) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child:             Text(title,
                style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textWeak,
                    fontWeight: FontWeight.w600)),
          ),
          Container(
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(AppRadii.md),
              border: Border.all(color: AppColors.divider),
            ),
            // 🔴 必须垫一层透明 Material：ListTile 的水波纹画在**最近的
            //    Material 祖先**上，而外面这个带背景色的 Container 是
            //    DecoratedBox 不是 Material —— 直接放 ListTile 的话
            //    点击反馈会被 Container 的背景吞掉（debug 下框架还会
            //    抛 "ink splashes may be invisible"）。transparency
            //    类型不改色， Container 的 surface 底色照旧透出来。
            child: Material(
              type: MaterialType.transparency,
              child: Column(
                children: [
                  for (var i = 0; i < children.length; i++) ...[
                    children[i],
                    if (i != children.length - 1)
                      Divider(height: 1, color: AppColors.divider),
                  ],
                ],
              ),
            ),
          ),
        ],
      );

  Widget _moduleFormatRow(String module, String moduleName) {
    final current = _s.formatOf(module);
    final def = ExportFormats.byId(current);
    return ListTile(
      title: Text(moduleName, style: const TextStyle(fontSize: 14)),
      subtitle: Text(def?.desc ?? current,
          style: TextStyle(fontSize: 11.5, color: AppColors.textWeak)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(def?.name ?? current,
              style: TextStyle(fontSize: 13, color: AppColors.brand)),
          Icon(Icons.chevron_right, size: 18, color: AppColors.textWeak),
        ],
      ),
      onTap: () async {
        final picked = await showModalBottomSheet<String>(
          context: context,
          backgroundColor: AppColors.surface,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          builder: (ctx) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final f in ExportFormats.forModule(module))
                  RadioListTile<String>(
                    value: f.id,
                    groupValue: current,
                    title: Text(f.name),
                    subtitle: Text(f.desc,
                        style: const TextStyle(fontSize: 11.5)),
                    onChanged: (v) => Navigator.pop(ctx, v),
                  ),
              ],
            ),
          ),
        );
        if (picked != null && picked != current) {
          _setModuleFormat(module, picked);
        }
      },
    );
  }

  Widget _enumRow(String label, String value, Map<String, String> options,
      void Function(String) onPick) {
    return ListTile(
      title: Text(label, style: const TextStyle(fontSize: 14)),
      trailing: Text(options[value] ?? value,
          style: TextStyle(fontSize: 13, color: AppColors.brand)),
      onTap: () async {
        final picked = await showDialog<String>(
          context: context,
          builder: (ctx) => SimpleDialog(
            backgroundColor: AppColors.surface,
            title: Text(label, style: const TextStyle(fontSize: 15)),
            children: [
              for (final e in options.entries)
                RadioListTile<String>(
                  value: e.key,
                  groupValue: value,
                  title: Text(e.value, style: const TextStyle(fontSize: 13.5)),
                  onChanged: (v) => Navigator.pop(ctx, v),
                ),
            ],
          ),
        );
        if (picked != null && picked != value) onPick(picked);
      },
    );
  }

  Widget _intRow(String label, int value, int min, int max,
      void Function(int) onPick) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Row(
        children: [
          Expanded(
              child: Text(label, style: const TextStyle(fontSize: 14))),
          _stepBtn(Icons.remove, value <= min
              ? null
              : () => onPick(value - 1)),
          SizedBox(
            width: 44,
            child: Text('$value',
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w600)),
          ),
          _stepBtn(Icons.add,
              value >= max ? null : () => onPick(value + 1)),
        ],
      ),
    );
  }

  Widget _stepBtn(IconData icon, VoidCallback? onTap) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          width: 28,
          height: 28,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.divider),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(icon,
              size: 15,
              color: onTap == null ? AppColors.textWeak : AppColors.text),
        ),
      );

  Widget _switchRow(String label, bool value, void Function(bool) onPick) =>
      SwitchListTile(
        title: Text(label, style: const TextStyle(fontSize: 14)),
        value: value,
        activeColor: AppColors.brand,
        onChanged: onPick,
      );

  Widget _notes() => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.bgElevated,
          borderRadius: BorderRadius.circular(AppRadii.md),
          border: Border.all(color: AppColors.divider),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('关于这些格式',
                style: TextStyle(
                    fontSize: 12.5,
                    color: AppColors.textSub,
                    fontWeight: FontWeight.w600)),
            SizedBox(height: 6),
            Text(
              '· 托利多 PLU / TXT 按 RL00 标准文本格式排版，商品名超过 14 个字会截断'
              '（SPCT 只认前 14 个汉字）；文件按 GBK 编码，SPCT 直接导入不乱码。\n'
              '· 单价单位是元/千克：商品单位是"斤"的会自动换算成两倍，'
              '否则秤上会按半价结账。\n'
              '· 通用 CSV 给 Excel / 盘点软件用；扫码文本文档是'
              '「条码 数量 商品名」空格分隔，给扫码枪类设备导入。',
              style: TextStyle(
                  fontSize: 11.5, color: AppColors.textWeak, height: 1.6),
            ),
          ],
        ),
      );
}

/// [ToledoParams] 的局部替换小助手（这个页面用得到，放文件末尾避免喧宾夺主）。
extension _ToledoParamsCopy on ToledoParams {
  ToledoParams copyWith({
    String? pluMode,
    String? priceMode,
    int? group,
    int? tare,
    int? tax,
    int? shelfLife,
    int? recommendLife,
    int? allowReprice,
    int? allowDiscount,
  }) =>
      ToledoParams(
        pluMode: pluMode ?? this.pluMode,
        priceMode: priceMode ?? this.priceMode,
        group: group ?? this.group,
        tare: tare ?? this.tare,
        tax: tax ?? this.tax,
        shelfLife: shelfLife ?? this.shelfLife,
        recommendLife: recommendLife ?? this.recommendLife,
        allowReprice: allowReprice ?? this.allowReprice,
        allowDiscount: allowDiscount ?? this.allowDiscount,
      );
}
