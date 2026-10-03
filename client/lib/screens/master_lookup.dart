import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../core/stock_master_repo.dart';
import '../core/theme.dart';
import 'camera_scan.dart';

/// 商档查询页。
///
/// ── 它解决什么 ─────────────────────────────────────────────────
/// 盘点和简易盘点里要"扫一下商品，跳出商档里该商品的所有信息"（龙哥 2026-10-03）。
/// 这一页就是干这个的：扫一个码 / 手输一个码 → 把本地 `stock_master` 里那条
/// 记录的**全部字段**摊开给员工看（条码/品名/规格/单位/单价/账面/进货价/来源/更新时间）。
///
/// ── 复用 ───────────────────────────────────────────────────────
/// 扫码直接复用通用相机控制器（`mobile_scanner`），和扫码枪同一套；
/// 查的是本地商档表（`StockMasterRepo.lookupLocal`），断网也能查。
/// 扫到一件就**停一下**显示结果，点「再扫一个」才恢复识别 —— 避免同一码反复上报。
class MasterLookupPage extends StatefulWidget {
  const MasterLookupPage({super.key});

  @override
  State<MasterLookupPage> createState() => _MasterLookupPageState();
}

class _MasterLookupPageState extends State<MasterLookupPage> {
  late final MobileScannerController? _cam = cameraScanSupported
      ? MobileScannerController(detectionSpeed: DetectionSpeed.normal)
      : null;

  String? _code;
  Map<String, dynamic>? _master;
  bool _notFound = false;
  bool _looking = false;
  final TextEditingController _input = TextEditingController();
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    _cam?.dispose();
    super.dispose();
  }

  /// 查一个条码并停镜显示结果。
  Future<void> _lookup(String raw) async {
    final code = raw.trim();
    if (code.isEmpty || _looking) return;
    setState(() {
      _looking = true;
      _code = code;
      _master = null;
      _notFound = false;
    });
    try {
      final row = await StockMasterRepo.instance.lookupLocal(code);
      if (!mounted) return;
      setState(() {
        _master = row;
        _notFound = row == null;
      });
      // 扫到就停镜，免得同一码反复上报把结果刷来刷去。
      await _cam?.stop();
    } finally {
      if (mounted) setState(() => _looking = false);
    }
  }

  /// 清空结果、恢复识别。
  Future<void> _resume() async {
    setState(() {
      _code = null;
      _master = null;
      _notFound = false;
      _input.clear();
    });
    await _cam?.start();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bgElevated,
        title: const Text('商档查询',
            style: TextStyle(color: AppColors.text, fontSize: 17)),
        actions: [
          if (_cam != null)
            IconButton(
              tooltip: '手电',
              icon: const Icon(Icons.flashlight_off, color: AppColors.textSub),
              onPressed: () async {
                await _cam.toggleTorch();
                if (!mounted) return;
                setState(() {});
              },
            ),
        ],
      ),
      body: Column(
        children: [
          // 相机区：扫到就停镜看结果。
          if (_cam != null)
            SizedBox(
              height: 240,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  MobileScanner(
                    controller: _cam,
                    fit: BoxFit.cover,
                    onDetect: (c) {
                      if (_code != null) return; // 正在显示结果，忽略
                      String? code;
                      for (final b in c.barcodes) {
                        final v = b.rawValue?.trim();
                        if (v != null && v.isNotEmpty) {
                          code = v;
                          break;
                        }
                      }
                      if (code != null) unawaited(_lookup(code));
                    },
                  ),
                  if (_code != null)
                    Positioned.fill(
                      child: Container(
                        color: Colors.black54,
                        child: const Center(
                          child: Icon(Icons.check_circle_outline,
                              color: Colors.white, size: 48),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          // 手动输入兜底（桌面没相机时用这个）。
          Container(
            color: AppColors.bgElevated,
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _input,
                    focusNode: _focus,
                    autofocus: true,
                    keyboardType: TextInputType.text,
                    enableSuggestions: false,
                    autocorrect: false,
                    textInputAction: TextInputAction.done,
                    style: const TextStyle(color: AppColors.text, fontSize: 15),
                    decoration: InputDecoration(
                      hintText: '手输条码查询',
                      hintStyle: const TextStyle(
                          color: AppColors.textWeak, fontSize: 13),
                      filled: true,
                      fillColor: AppColors.surface,
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 12),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(10),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    onSubmitted: _lookup,
                  ),
                ),
                const SizedBox(width: 10),
                IconButton(
                  tooltip: '查询',
                  icon: const Icon(Icons.search, color: AppColors.brand),
                  onPressed: () => _lookup(_input.text),
                ),
              ],
            ),
          ),
          Expanded(child: _resultArea()),
        ],
      ),
    );
  }

  Widget _resultArea() {
    if (_looking) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_code == null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            _cam != null ? '把商品条码对准摄像头，或手输条码查询' : '手输条码查询商档',
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.textWeak, fontSize: 13),
          ),
        ),
      );
    }
    if (_notFound || _master == null) {
      return _card(
        color: AppColors.warn,
        icon: Icons.help_outline,
        title: '商档里没有这个条码',
        body: '条码：$_code\n（请确认条码是否正确，或先同步商档）',
      );
    }
    return _masterCard(_master!);
  }

  Widget _card({
    required Color color,
    required IconData icon,
    required String title,
    required String body,
  }) =>
      Padding(
        padding: const EdgeInsets.all(14),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(AppRadii.md),
            border: Border.all(color: color.withValues(alpha: 0.5)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(icon, color: color, size: 22),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(title,
                        style: TextStyle(
                            color: AppColors.text,
                            fontSize: 16,
                            fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(body,
                  style: const TextStyle(color: AppColors.textSub, fontSize: 13)),
              const SizedBox(height: 16),
              _resumeButton(),
            ],
          ),
        ),
      );

  Widget _masterCard(Map<String, dynamic> m) {
    const labels = <String, String>{
      'barcode': '条码',
      'name': '品名',
      'spec': '规格',
      'unit': '单位',
      'unit_price': '单价',
      'account_qty': '账面数量',
      'purchase_price': '进货价',
      'source': '来源',
      'updated_at': '更新时间',
    };
    final order = [
      'barcode',
      'name',
      'spec',
      'unit',
      'unit_price',
      'account_qty',
      'purchase_price',
      'source',
      'updated_at',
    ];
    final rows = <MapEntry<String, String>>[];
    for (final k in order) {
      if (m.containsKey(k)) {
        rows.add(MapEntry(labels[k] ?? k, _fmt(k, m[k])));
      }
    }
    // 任何表里多出来的字段也一并显示（不漏信息）。
    for (final k in m.keys) {
      if (!order.contains(k)) {
        rows.add(MapEntry(k, _fmt(k, m[k])));
      }
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(14),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppColors.brand.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(AppRadii.md),
          border: Border.all(color: AppColors.brand.withValues(alpha: 0.45)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.inventory_2_outlined,
                    color: AppColors.brand, size: 22),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('商档信息',
                      style: TextStyle(
                          color: AppColors.text,
                          fontSize: 16,
                          fontWeight: FontWeight.w600)),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ...rows.map((e) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 76,
                        child: Text(e.key,
                            style: const TextStyle(
                                color: AppColors.textWeak, fontSize: 13)),
                      ),
                      Expanded(
                        child: Text(e.value,
                            style: const TextStyle(
                                color: AppColors.text, fontSize: 14)),
                      ),
                    ],
                  ),
                )),
            const SizedBox(height: 16),
            _resumeButton(),
          ],
        ),
      ),
    );
  }

  String _fmt(String key, Object? v) {
    if (v == null) return '—';
    if (key == 'updated_at') {
      final ms = v is int ? v : int.tryParse(v.toString());
      if (ms == null) return v.toString();
      final d = DateTime.fromMillisecondsSinceEpoch(ms);
      String two(int x) => x.toString().padLeft(2, '0');
      return '${d.year}-${two(d.month)}-${two(d.day)} '
          '${two(d.hour)}:${two(d.minute)}';
    }
    if (v is num) {
      final d = v.toDouble();
      if (d == d.roundToDouble()) return d.toStringAsFixed(0);
      return d.toStringAsFixed(3).replaceAll(RegExp(r'0+$'), '').replaceAll(
          RegExp(r'\.$'), '');
    }
    return v.toString();
  }

  Widget _resumeButton() => SizedBox(
        width: double.infinity,
        height: 40,
        child: FilledButton.tonal(
          onPressed: _resume,
          child: const Text('再扫一个', style: TextStyle(fontSize: 14)),
        ),
      );
}
