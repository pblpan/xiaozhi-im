import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:xiaozhi_im_client/core/bt_printer.dart';
import 'package:xiaozhi_im_client/core/local_db.dart';
import 'package:xiaozhi_im_client/core/price_tag.dart';
import 'package:xiaozhi_im_client/core/theme.dart';

/// 蓝牙价签打印。
///
/// ── 这页干什么 ──────────────────────────────────────────────────
/// 选几个商品 → 改价 → 打标签贴到货架上。
/// 现场是"一批货上完架、顺手把这几十张打了"，不是"先建一张单子再慢慢填"，
/// 所以入口就是**一个扫码框**，扫一个进一行，打完就完了。
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
    required this.unit,
    required this.copies,
    required this.inMaster,
  });

  final String barcode;
  final String name;
  String spec;
  double price;
  final String unit;
  int copies;
  final bool inMaster;

  PriceTagItem toItem() => PriceTagItem(
        barcode: barcode,
        name: name,
        spec: spec,
        price: price,
        unit: unit,
        copies: copies,
      );
}

class _PriceTagPrintPageState extends State<PriceTagPrintPage> {
  final _ctrl = TextEditingController();
  final FocusNode _focus = FocusNode();
  final List<_Row> _rows = <_Row>[];

  String _header = '';
  LabelSize _label = LabelSize.mm58;
  bool _busy = false;
  bool _connected = false;

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
        'SELECT name, spec, unit, unit_price FROM stock_master WHERE barcode = ?',
        <Object?>[code],
      );
      if (rs.isNotEmpty) m = rs.first;
    } catch (_) {
      // 商档表读不出来不该拦住打价签：手打字也是一回事，
      // 拦在这里的结果是"打印机闲着、人在等"。
    }

    final inMaster = m != null;
    setState(() {
      _rows.add(_Row(
        barcode: code,
        name: (m?['name'] as String? ?? '').trim(),
        spec: (m?['spec'] as String? ?? '').trim(),
        price: _num(m?['unit_price']) ?? 0,
        unit: (m?['unit'] as String? ?? '').trim(),
        copies: 1,
        inMaster: inMaster,
      ));
    });
    if (!inMaster) {
      _say('商档里没有 $code —— 名字和售价要手填，打出来才知道对不对');
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
    final specCtrl = TextEditingController(text: r.spec);
    final copyCtrl = TextEditingController(text: r.copies.toString());
    showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(r.name.isEmpty ? r.barcode : r.name),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: priceCtrl,
              decoration: const InputDecoration(labelText: '售价（元）'),
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
              setState(() {
                r.price = p;
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
      final bytes = PriceTagPrinter(label: _label)
          .render(_rows.map((r) => r.toItem()).toList(), header: _header);
      await link.write(bytes);
      await link.close();
      _connected = false;
      if (!mounted) return;
      _say('已发送 ${_rows.length} 张价签（共 ${_rows.fold<int>(0, (s, r) => s + r.copies)} 张）');
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
    final bytes = PriceTagPrinter(label: _label)
        .render(_rows.map((r) => r.toItem()).toList(), header: _header);
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

  // ---------------- 界面 ----------------

  @override
  Widget build(BuildContext context) {
    final canPrint = BtPrinter.supported;
    return Scaffold(
      appBar: AppBar(title: const Text('价签打印')),
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
          _Options(
            header: _header,
            label: _label,
            onHeader: (v) => setState(() => _header = v),
            onLabel: (v) => setState(() => _label = v),
          ),
          Expanded(child: _rows.isEmpty ? _EmptyRows(canPrint: canPrint) : _List(rows: _rows, onEdit: _edit)),
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
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 160),
      color: Colors.grey.shade100,
      padding: const EdgeInsets.all(10),
      child: SingleChildScrollView(
        child: Text(
          PriceTagPrinter(label: _label)
              .preview(_rows.map((r) => r.toItem()).toList(), header: _header),
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
      ),
    );
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

class _Options extends StatelessWidget {
  const _Options({
    required this.header,
    required this.label,
    required this.onHeader,
    required this.onLabel,
  });

  final String header;
  final LabelSize label;
  final ValueChanged<String> onHeader;
  final ValueChanged<LabelSize> onLabel;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Row(
        children: [
          // 刻意不给 controller：页面重建频繁，每次 new 一个再丢掉会漏 dispose。
          // 值由父级持有，这里只负责把输入回传上去。
          Expanded(
            child: TextField(
              onChanged: onHeader,
              decoration: const InputDecoration(
                labelText: '抬头（可空，印在每张顶部）',
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: 8),
          DropdownButton<LabelSize>(
            value: label,
            items: [
              for (final s in LabelSize.presets)
                DropdownMenuItem<LabelSize>(value: s, child: Text(s.name)),
            ],
            onChanged: (v) {
              if (v != null) onLabel(v);
            },
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
        return ListTile(
          title: Text(r.name.isEmpty ? r.barcode : r.name),
          subtitle: Text(
            '${r.barcode} · ${r.spec.isEmpty ? r.unit : r.spec} · '
            '${PriceTagPrinter.fmtPrice(r.price)} × ${r.copies}',
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
