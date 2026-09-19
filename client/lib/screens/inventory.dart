import 'package:flutter/material.dart';

import '../core/inventory_repo.dart';
import '../core/stock_master_repo.dart';
import '../core/theme.dart';
import 'inventory_collect.dart';

/// 盘点：入口页（盘点位列表）。
///
/// ── 这一页和「扫码枪」什么关系 ────────────────────────────────
/// 扫码枪 = 把条码快速扫成一笔账（工具）。
/// 盘点 = 盘点制度：盘点位 / 库位货架位 / 初盘-复盘-抽盘三遍制。
/// 两者的区别在**有没有"位置"和"阶段"这两个维度**。
/// 所以这一页的第一件事不是扫码，而是"你盘哪个点位"。
///
/// ── 为什么一进来是点位列表，而不是直接进扫码 ──────────────────
/// 盘点单是"一个点位 × 一个阶段"，点位没确定就无从谈起。
/// 直接进扫码的话，扫出来的数据不知道属于哪个区，最后没人敢用。
class InventoryPage extends StatefulWidget {
  const InventoryPage({super.key});

  @override
  State<InventoryPage> createState() => _InventoryPageState();
}

class _InventoryPageState extends State<InventoryPage> {
  final InventoryRepo _repo = InventoryRepo();

  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _zones = const [];
  int _masterCount = 0;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final zones = await _repo.listZones();
      final master = await StockMasterRepo().countLocal();
      if (!mounted) return;
      setState(() {
        _zones = zones;
        _masterCount = master;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '读取本地数据失败：$e';
      });
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 新建 / 改盘点位。
  ///
  /// 码和名分开两个输入框，不是多此一举：**码是扫出来的、名是人起的**。
  /// 现场的做法是货架旁边贴一张点位码，扫一下得到 `Z01`，
  /// 而人记得住的是"生鲜区"。只给一个输入框的话，要么码是中文没法用，
  /// 要么名字是 Z01 谁也看不懂。
  Future<void> _newZone() async {
    final codeCtl = TextEditingController();
    final nameCtl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: const Text('新建盘点位',
            style: TextStyle(color: AppColors.text, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const Key('zone-code-input'),
              controller: codeCtl,
              autofocus: true,
              style: const TextStyle(color: AppColors.text, fontSize: 15),
              decoration: const InputDecoration(
                labelText: '盘点位码（扫货架旁的点位码）',
                labelStyle: TextStyle(color: AppColors.textWeak, fontSize: 13),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('zone-name-input'),
              controller: nameCtl,
              style: const TextStyle(color: AppColors.text, fontSize: 15),
              decoration: const InputDecoration(
                labelText: '名字（如 生鲜区，可留空）',
                labelStyle: TextStyle(color: AppColors.textWeak, fontSize: 13),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('建好',
                  style: TextStyle(
                      color: AppColors.brand, fontWeight: FontWeight.w600))),
        ],
      ),
    );
    final code = codeCtl.text.trim();
    final name = nameCtl.text.trim();
    codeCtl.dispose();
    nameCtl.dispose();
    if (ok != true || !mounted) return;
    if (code.isEmpty) {
      _snack('盘点位码不能为空');
      return;
    }
    if (code.contains('/') || code.contains('\\')) {
      // 点位码会进单号、进而进导出文件名；带斜杠会被当成目录。
      _snack('盘点位码不能带 / 或 \\');
      return;
    }
    try {
      await _repo.saveZone(code: code, name: name.isEmpty ? code : name);
      await _reload();
      if (!mounted) return;
      _snack('已建盘点位 $code');
    } catch (e) {
      _snack('新建失败：$e');
    }
  }

  Future<void> _toggleLock(Map<String, dynamic> z) async {
    final locked = (z['locked'] as num? ?? 0).toInt() != 0;
    try {
      await _repo.setZoneLocked(z['zone_code'] as String, !locked);
      await _reload();
      _snack(locked ? '已解除锁定' : '已锁定：锁定后不能再往里扫');
    } catch (e) {
      _snack('操作失败：$e');
    }
  }

  /// 删除盘点位：不可逆，且会连带删掉该点位的库位、绑定、单据与明细。
  /// 二次确认里把**要删掉多少东西**说清楚 —— 只说"确定删除吗"没人看得懂代价。
  Future<void> _deleteZone(Map<String, dynamic> z) async {
    final code = z['zone_code'] as String;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: const Text('删除盘点位（不可恢复）',
            style: TextStyle(color: AppColors.text, fontSize: 16)),
        content: Text(
          '将删除「${z['zone_name'] ?? code}」以及它的 '
          '${z['loc_count'] ?? 0} 个货架位、商品与货架位的绑定关系、'
          '该点位下的全部盘点单与明细。\n\n此操作不可撤销。',
          style: const TextStyle(color: AppColors.textSub, fontSize: 13),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除',
                  style: TextStyle(color: AppColors.danger))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await _repo.deleteZone(code);
      await _reload();
      _snack('已删除盘点位 $code');
    } catch (e) {
      _snack('删除失败：$e');
    }
  }

  /// 清空**全部**盘点数据（点位与货架位档案保留）。
  Future<void> _clearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: const Text('清除全部盘点数据（不可恢复）',
            style: TextStyle(color: AppColors.text, fontSize: 16)),
        content: const Text(
          '会删掉所有点位的盘点单与扫码明细。\n'
          '盘点位、货架位、商品绑定这些**档案**会保留。\n\n'
          '（只清本机数据，已经同步到服务端的不会被删。）',
          style: TextStyle(color: AppColors.textSub, fontSize: 13),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('清除', style: TextStyle(color: AppColors.danger))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final r = await _repo.clearAllData();
      await _reload();
      _snack('已清除 ${r['sheet'] ?? 0} 张盘点单、${r['scan_record'] ?? 0} 条明细');
    } catch (e) {
      _snack('清除失败：$e');
    }
  }

  Future<void> _syncMaster() async {
    _snack('正在同步商品档案…');
    try {
      final n = await StockMasterRepo().sync();
      await _reload();
      _snack('已同步 $n 个商品');
    } catch (e) {
      _snack('同步失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bgElevated,
        title: const Text('盘点',
            style: TextStyle(color: AppColors.text, fontSize: 17)),
        actions: [
          IconButton(
            tooltip: '同步商品档案',
            icon: const Icon(Icons.sync, color: AppColors.textSub),
            onPressed: _syncMaster,
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: AppColors.textSub),
            onSelected: (v) {
              if (v == 'clear') _clearAll();
            },
            itemBuilder: (_) => const [
              PopupMenuItem<String>(
                value: 'clear',
                child: Text('清除本机全部盘点数据'),
              ),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        key: const Key('new-zone'),
        onPressed: _newZone,
        backgroundColor: AppColors.brand,
        icon: const Icon(Icons.add),
        label: const Text('新建盘点位'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (_error != null) _banner(_error!, AppColors.danger),
                if (_masterCount == 0)
                  _banner(
                    '这台设备还没有商品档案，盘出来的都是"未知条码"（没有账面数量，'
                    '差异算不出来）。请先在有网的地方点右上角同步一次。',
                    AppColors.warn,
                  ),
                Expanded(child: _zones.isEmpty ? _empty() : _list()),
              ],
            ),
    );
  }

  Widget _banner(String text, Color color) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        color: color.withValues(alpha: 0.14),
        child: Text(text, style: TextStyle(color: color, fontSize: 13)),
      );

  Widget _empty() => const Center(
        child: Padding(
          padding: EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.inventory_2_outlined,
                  size: 46, color: AppColors.textWeak),
              const SizedBox(height: 14),
              const Text('还没有盘点位',
                  style: TextStyle(color: AppColors.text, fontSize: 15)),
              const SizedBox(height: 8),
              const Text(
                '盘点先定"盘哪儿"：一个货架区就是一个盘点位。\n'
                '点下面的「新建盘点位」，扫一下货架旁的点位码\n'
                '（或直接输一个编号，比如 Z01）就能开始。',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.textWeak, fontSize: 13),
              ),
            ],
          ),
        ),
      );

  Widget _list() => ListView.separated(
        padding: const EdgeInsets.only(top: 6, bottom: 96),
        itemCount: _zones.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (_, i) => _zoneCard(_zones[i]),
      );

  Widget _zoneCard(Map<String, dynamic> z) {
    final code = z['zone_code'] as String;
    final locked = (z['locked'] as num? ?? 0).toInt() != 0;
    final locCount = (z['loc_count'] as num? ?? 0).toInt();
    return Padding(
      key: ValueKey<String>('zone-$code'),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadii.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadii.md),
          onTap: () async {
            await Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => InventoryCollectPage(
                  zoneCode: code,
                  zoneName: (z['zone_name'] ?? code).toString(),
                ),
              ),
            );
            if (!mounted) return;
            await _reload();
          },
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
            child: Row(
              children: [
                Icon(locked ? Icons.lock_outline : Icons.inventory_2_outlined,
                    color: locked ? AppColors.warn : AppColors.brand, size: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              (z['zone_name'] ?? code).toString(),
                              style: const TextStyle(
                                  color: AppColors.text,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (locked) ...[
                            const SizedBox(width: 6),
                            const _Chip(text: '已锁定', color: AppColors.warn),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '$code　·　$locCount 个货架位'
                        '${(z['open_sheets'] as num? ?? 0) > 0 ? '　·　有未完成的单' : ''}',
                        style: const TextStyle(
                            color: AppColors.textWeak, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_vert,
                      color: AppColors.textWeak, size: 20),
                  onSelected: (v) {
                    if (v == 'lock') _toggleLock(z);
                    if (v == 'delete') _deleteZone(z);
                  },
                  itemBuilder: (_) => [
                    PopupMenuItem<String>(
                        value: 'lock', child: Text(locked ? '解除锁定' : '锁定盘点位')),
                    const PopupMenuItem<String>(
                        value: 'delete', child: Text('删除盘点位')),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 小胶囊标签（状态用）。
class _Chip extends StatelessWidget {
  const _Chip({required this.text, required this.color});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(text, style: TextStyle(color: color, fontSize: 11)),
      );
}
