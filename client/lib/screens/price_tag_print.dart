import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:xiaozhi_im_client/core/bt_printer.dart';
import 'package:xiaozhi_im_client/core/local_db.dart';
import 'package:xiaozhi_im_client/core/price_tag.dart';
import 'package:xiaozhi_im_client/core/price_tag_store.dart';
import 'package:xiaozhi_im_client/core/price_tag_template.dart';
import 'package:xiaozhi_im_client/core/theme.dart';
import 'package:xiaozhi_im_client/screens/price_tag_template_page.dart';
import 'package:xiaozhi_im_client/widgets/price_tag_preview.dart';

/// 蓝牙价签打印。
///
/// ── 这页干什么 ──────────────────────────────────────────────────
/// 选几个商品 → 选一张模板 → 打标签贴到货架上。
/// 现场是"一批货上完架、顺手把这几十张打了"，不是"先建一张单子再慢慢填"，
/// 所以入口就是**一个扫码框**，扫一个进一行，打完就完了。
///
/// ── 模板（2026-10-16 加）──────────────────────────────────────
/// 原来只有一种写死的排版。但货架上的标签从来不止一种：日常货架是
/// 「品名 + 价 + 条码」，堆头促销是「原价划掉 + 促销价反白」，
/// 生鲜要带「元/kg」，会员商品要印会员价。
/// 所以改成**先选模板再打** —— 模板决定了这张纸上印什么、字多大、纸多宽。
/// 纸宽跟着模板走（原来那个单独的"纸宽"下拉撤了）：40mm 的模板配 58mm
/// 的纸宽只会让条码右半边打不出来，两件事必须由同一个选择决定。
///
/// ── 为什么不存账单 ──────────────────────────────────────────────
/// 盘点、减货、补货都是"要交出去的单子"，所以要落库所以对账。
/// 价签不是单子：它打完就贴在货上了，没有第二方要认它。
/// 存下来唯一的用处是"重打"，而重打用"上次打的那批"复刻一遍就行 ——
/// 为此单开一张表，是给自己加麻烦。
///
/// ── 平台 ───────────────────────────────────────────────────────
/// 只有 **Android** 能打（经典蓝牙串口）。桌面端进来会看到一段明说不支持的话，
/// 而不是点了打印转半天然后失败。
class PriceTagPrintPage extends StatefulWidget {
  const PriceTagPrintPage({super.key});

  @override
  State<PriceTagPrintPage> createState() => _PriceTagPrintPageState();
}

class _Row {
  _Row({
    required this.barcode,
    required this.name,
    required this.spec,
    required this.price,
    required this.memberPrice,
    required this.originPrice,
    required this.unit,
    required this.copies,
    required this.inMaster,
  });

  final String barcode;
  final String name;
  String spec;
  double price;
  double memberPrice;
  double originPrice;
  final String unit;
  int copies;
  final bool inMaster;

  PriceTagItem toItem() => PriceTagItem(
        barcode: barcode,
        name: name,
        spec: spec,
        price: price,
        memberPrice: memberPrice,
        originPrice: originPrice,
        unit: unit,
        copies: copies,
      );
}

class _PriceTagPrintPageState extends State<PriceTagPrintPage> {
  final _ctrl = TextEditingController();
  final FocusNode _focus = FocusNode();
  final List<_Row> _rows = <_Row>[];

  List<PriceTagTemplate> _tpls = List<PriceTagTemplate>.from(kBuiltinTagTemplates);
  PriceTagTemplate _tpl = kBuiltinTagTemplates.first;
  bool _tplLoading = true;
  bool _busy = false;
  bool _connected = false;

  @override
  void initState() {
    super.initState();
    _loadTemplates();
  }

  /// 模板列表 + 上次选的那张。
  ///
  /// 🔴 加载失败时**用内置模板顶上**，不弹错误：模板读不出来只影响
  ///    "少几个选择"，而弹一个看不懂的错误会让现场以为这个页面坏了。
  Future<void> _loadTemplates() async {
    final all = await PriceTagStore.I.list();
    final last = await PriceTagStore.I.last();
    if (!mounted) return;
    setState(() {
      _tpls = all;
      _tpl = all.firstWhere((t) => t.id == last, orElse: () => all.first);
      _tplLoading = false;
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    _focus.dispose();
    super.dispose();
  }

  // ---------------- 加行 ----------------

  Future<void> _add(String raw) async {
    final code = raw.trim();
    if (code.isEmpty) return;
    if (_rows.any((r) => r.barcode == code)) {
      _say('$code 已经在单上了，改价就行');
      return;
    }

    Map<String, Object?>? m;
    try {
      final db = await LocalDb.I.db();
      final rs = await db.rawQuery(
        'SELECT name, spec, unit, unit_price, member_price, special_price '
        'FROM stock_master WHERE barcode = ?',
        <Object?>[code],
      );
      if (rs.isNotEmpty) m = rs.first;
    } catch (_) {
      // 商档表读不出来不该拦住打价签：手打字也是一回事，
      // 拦在这里的结果是"打印机闲着、人在等"。
    }

    final inMaster = m != null;
    // 商档里有特价，且特价确实比售价低 → 认为这个商品正在做特价：
    // 价签上印特价、把原售价顶到"原价"那一栏（促销模板划掉它）。
    //
    // 🔴 判断必须带上 `special > 0`：特价列在没做促销的商品上是 0 或 NULL，
    //    直接拿它当售价会印出「￥0.00」 —— 一张白送的标签贴在货架上，
    //    顾客会当真，而打标签的人根本不知道自己干了什么。
    var price = _num(m?['unit_price']) ?? 0;
    var origin = 0.0;
    final special = _num(m?['special_price']) ?? 0;
    if (special > 0 && special < price) {
      origin = price;
      price = special;
    }

    setState(() {
      _rows.add(_Row(
        barcode: code,
        name: (m?['name'] as String? ?? '').trim(),
        spec: (m?['spec'] as String? ?? '').trim(),
        price: price,
        memberPrice: _num(m?['member_price']) ?? 0,
        originPrice: origin,
        unit: (m?['unit'] as String? ?? '').trim(),
        copies: 1,
        inMaster: inMaster,
      ));
    });
    if (!inMaster) {
      _say('商档里没有 $code —— 名字和售价要手填，打出来才知道对不对');
    } else if (origin > 0) {
      _say('这个商品正在做特价，按特价 $price 印（原价 ${origin}划掉）');
    }
  }

  static double? _num(dynamic v) {
    if (v == null) return null;
    if (v is num) return v.toDouble();
    return double.tryParse(v.toString());
  }

  void _say(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(s), duration: const Duration(seconds: 4)));
  }

  void _edit(int i) {
    final r = _rows[i];
    final priceCtrl = TextEditingController(text: r.price.toStringAsFixed(2));
    final memCtrl = TextEditingController(
        text: r.memberPrice > 0 ? r.memberPrice.toStringAsFixed(2) : '');
    final originCtrl = TextEditingController(
        text: r.originPrice > 0 ? r.originPrice.toStringAsFixed(2) : '');
    final specCtrl = TextEditingController(text: r.spec);
    final copyCtrl = TextEditingController(text: r.copies.toString());
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(r.name.isEmpty ? r.barcode : r.name),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: priceCtrl,
                decoration: const InputDecoration(labelText: '售价（元）'),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
              ),
              TextField(
                controller: memCtrl,
                decoration: const InputDecoration(
                    labelText: '会员价（可空，留空不印）',
                    helperText: '只有带会员价元素的模板会印它'),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
              ),
              TextField(
                controller: originCtrl,
                decoration: const InputDecoration(
                    labelText: '原价（可空，留空不印）',
                    helperText: '高于售价才印，促销模板会把它划掉'),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
              ),
              TextField(
                controller: specCtrl,
                decoration: const InputDecoration(labelText: '规格（可空）'),
              ),
              TextField(
                controller: copyCtrl,
                decoration: const InputDecoration(labelText: '份数'),
                keyboardType: TextInputType.number,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('取消')),
          TextButton(
            onPressed: () {
              final p = double.tryParse(priceCtrl.text.trim());
              final n = int.tryParse(copyCtrl.text.trim());
              if (p == null || p < 0) {
                _say('售价得是个不小于 0 的数');
                return;
              }
              final mem = double.tryParse(memCtrl.text.trim()) ?? 0;
              final org = double.tryParse(originCtrl.text.trim()) ?? 0;
              if (org > 0 && org <= p) {
                _say('原价得比售价高，不然就是没做促销 —— 留空即可');
                return;
              }
              setState(() {
                r.price = p;
                r.memberPrice = mem;
                r.originPrice = org;
                r.spec = specCtrl.text.trim();
                r.copies = (n == null || n < 1) ? 1 : n;
              });
              Navigator.pop(c);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  // ---------------- 打印 ----------------

  List<int> _bytes() {
    // 打印器的纸宽必须跟着模板走 —— 40mm 的模板配 58mm 的纸宽，
    // 条码右半边会打在纸外面（line() 也算纸宽）
    final printer = PriceTagPrinter(
        label: LabelSize(_tpl.name, _tpl.widthMm));
    return printer.renderWithTemplate(_rows.map((r) => r.toItem()).toList(), _tpl);
  }

  Future<void> _pickAndPrint() async {
    if (_rows.isEmpty) {
      _say('先扫几个商品码');
      return;
    }
    if (!BtPrinter.supported) {
      _say(BtPrinter.unsupportedReason);
      return;
    }

    setState(() => _busy = true);
    try {
      if (!await BtPrinter.ensurePermission()) {
        _say('蓝牙权限还没给。到「设置 → 应用 → 权限」里打开蓝牙，再回来打印。');
        return;
      }
      final peers = await BtPrinter.listPaired();
      if (peers.isEmpty) {
        _say('没找到配对过的打印机。到「设置 → 蓝牙」里先和它配对一次，再回来打印。');
        return;
      }
      if (!mounted) return;

      final picked = await showDialog<BtPrinterDevice>(
        context: context,
        builder: (c) => SimpleDialog(
          title: const Text('选一台打印机'),
          children: [
            for (final p in peers)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(c, p),
                child: Text(p.displayName),
              ),
          ],
        ),
      );
      if (picked == null) return;

      final link = await BtPrinter.connect(picked);
      _connected = true;
      await link.write(_bytes());
      await link.close();
      _connected = false;
      if (!mounted) return;
      final n = _rows.fold<int>(0, (s, r) => s + r.copies);
      _say('已发送 ${_rows.length} 种、共 $n 张（模板：${_tpl.name}）');
    } catch (e) {
      final err = BtPrinter.explain(e);
      _say(err.message);
    } finally {
      _connected = false;
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 把指令存成文件。桌面端打不了，但至少排障时能拿一份"到底发了什么"。
  Future<void> _saveBytes() async {
    if (_rows.isEmpty) {
      _say('先扫几个商品码');
      return;
    }
    final bytes = _bytes();
    String? dir;
    try {
      dir = (await getApplicationDocumentsDirectory()).path;
    } catch (_) {
      _say('拿不到保存目录');
      return;
    }
    final f = File('$dir/价签指令-${DateTime.now().millisecondsSinceEpoch}.bin');
    await f.writeAsBytes(bytes);
    if (!mounted) return;
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('指令已存下'),
        content: Text('${f.path}\n\n这段就是发给打印机的原始字节。'),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('好'))],
      ),
    );
  }

  Future<void> _openTemplates() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => const PriceTagTemplatePage()),
    );
    // 回来**重新拉一遍**：在管理页里可能删了当前这张，
    // 继续按旧引用打印的话，纸宽和内容会对不上刚看到的预览
    await _loadTemplates();
  }

  // ---------------- 界面 ----------------

  @override
  Widget build(BuildContext context) {
    final canPrint = BtPrinter.supported;
    return Scaffold(
      appBar: AppBar(
        title: const Text('价签打印'),
        actions: [
          IconButton(
            tooltip: '模板管理',
            icon: const Icon(Icons.dashboard_customize_outlined),
            onPressed: _openTemplates,
          ),
        ],
      ),
      body: Column(
        children: [
          _ScanBar(
            controller: _ctrl,
            focus: _focus,
            busy: _busy,
            onSubmit: (v) async {
              await _add(v);
              if (!mounted) return;
              _ctrl.clear();
              _focus.requestFocus();
            },
          ),
          _TemplateBar(
            templates: _tpls,
            current: _tpl,
            loading: _tplLoading,
            onPick: (t) async {
              setState(() => _tpl = t);
              await PriceTagStore.I.setLast(t.id);
            },
            onManage: _openTemplates,
          ),
          Expanded(
            child: _rows.isEmpty
                ? _EmptyRows(canPrint: canPrint)
                : _List(rows: _rows, onEdit: _edit),
          ),
          _preview(),
          _Actions(
            canPrint: canPrint,
            busy: _busy,
            connected: _connected,
            rowCount: _rows.length,
            onPrint: _pickAndPrint,
            onSave: _saveBytes,
          ),
        ],
      ),
    );
  }

  Widget _preview() {
    if (_rows.isEmpty) return const SizedBox.shrink();
    // 🔴 预览的是**第一张**就够了：同一批用的同一套模板，
    //    把 30 张全画出来只会在手机上卡住，而且看不到任何新信息。
    final item = _rows.first.toItem();
    return Container(
      width: double.infinity,
      color: const Color(0xFFECEFF1),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          PriceTagPreview(
            template: _tpl,
            item: item,
            dateText: _today(),
            seq: 1,
            maxPxPerMm: 3.4,
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              _rows.length > 1 ? '预览第 1 张（共 ${_rows.length} 种）' : '打印预览',
              style: const TextStyle(fontSize: 11.5, color: AppColors.textSub),
            ),
          ),
        ],
      ),
    );
  }

  static String _today() {
    final d = DateTime.now();
    final mm = d.month.toString().padLeft(2, '0');
    final dd = d.day.toString().padLeft(2, '0');
    return '${d.year}-$mm-$dd';
  }
}

// ── 下面都是小部件，跟页面逻辑分开，方便单独读 ──────────────────────

class _ScanBar extends StatelessWidget {
  const _ScanBar({
    required this.controller,
    required this.focus,
    required this.busy,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final FocusNode focus;
  final bool busy;
  final Future<void> Function(String) onSubmit;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: TextField(
        controller: controller,
        focusNode: focus,
        enabled: !busy,
        decoration: const InputDecoration(
          labelText: '扫条码或手输商品码，回车加一行',
          border: OutlineInputBorder(),
        ),
        onSubmitted: onSubmit,
      ),
    );
  }
}

/// 模板选择条：纸宽跟着模板走，不再单独选。
class _TemplateBar extends StatelessWidget {
  const _TemplateBar({
    required this.templates,
    required this.current,
    required this.loading,
    required this.onPick,
    required this.onManage,
  });

  final List<PriceTagTemplate> templates;
  final PriceTagTemplate current;
  final bool loading;
  final ValueChanged<PriceTagTemplate> onPick;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: loading
                ? const SizedBox(
                    height: 40,
                    child: Center(child: SizedBox(
                        width: 16, height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))),
                  )
                : DropdownButtonFormField<PriceTagTemplate>(
                    initialValue: current,
                    isExpanded: true,
                    isDense: true,
                    decoration: InputDecoration(
                      labelText: '模板（${current.widthMm}×${current.heightMm}mm）',
                      border: const OutlineInputBorder(),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                    ),
                    items: [
                      for (final t in templates)
                        DropdownMenuItem<PriceTagTemplate>(
                          value: t,
                          child: Text(
                            '${t.name}　${t.widthMm}×${t.heightMm}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (v) {
                      if (v != null) onPick(v);
                    },
                  ),
          ),
          const SizedBox(width: 8),
          // 直接进模板管理：手机上下拉框里塞 20 个模板是没法用的，
          // 真正的"选一个"应该在管理页里看着预览挑
          OutlinedButton.icon(
            onPressed: onManage,
            icon: const Icon(Icons.dashboard_customize_outlined, size: 18),
            label: const Text('管理'),
          ),
        ],
      ),
    );
  }
}

class _EmptyRows extends StatelessWidget {
  const _EmptyRows({required this.canPrint});

  final bool canPrint;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.label_off_outlined, size: 44),
            const SizedBox(height: 10),
            Text(canPrint ? '扫一个商品码，这行就出来了' : '先扫商品码'),
            if (!canPrint)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Text(
                  BtPrinter.unsupportedReason,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.textSub),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _List extends StatelessWidget {
  const _List({required this.rows, required this.onEdit});

  final List<_Row> rows;
  final void Function(int) onEdit;

  @override
  Widget build(BuildContext context) {
    return ListView.separated(
      itemCount: rows.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (c, i) {
        final r = rows[i];
        final extra = <String>[
          if (r.memberPrice > 0) '会员 ${PriceTagPrinter.fmtPrice(r.memberPrice)}',
          if (r.originPrice > r.price) '原价 ${PriceTagPrinter.fmtPrice(r.originPrice)}',
        ];
        return ListTile(
          title: Text(r.name.isEmpty ? r.barcode : r.name),
          subtitle: Text(
            '${r.barcode} · ${r.spec.isEmpty ? r.unit : r.spec} · '
            '${PriceTagPrinter.fmtPrice(r.price)} × ${r.copies}'
            '${extra.isEmpty ? '' : '　${extra.join(' ')}'}',
          ),
          trailing: IconButton(
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => onEdit(i),
          ),
          onTap: () => onEdit(i),
        );
      },
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({
    required this.canPrint,
    required this.busy,
    required this.connected,
    required this.rowCount,
    required this.onPrint,
    required this.onSave,
  });

  final bool canPrint;
  final bool busy;
  final bool connected;
  final int rowCount;
  final Future<void> Function() onPrint;
  final Future<void> Function() onSave;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: canPrint && !busy && rowCount > 0 ? onPrint : null,
              icon: const Icon(Icons.print),
              label: Text(busy ? '打印中…' : (connected ? '继续打' : '打印')),
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: rowCount == 0 ? null : onSave,
            icon: const Icon(Icons.save_outlined),
            label: const Text('存指令'),
          ),
        ],
      ),
    );
  }
}
