import 'dart:io';

import 'package:flutter/material.dart';

import '../api.dart';
import '../core/file_io.dart';
import '../core/time.dart';
import '../core/theme.dart';

/// 导出记录页（个人中心 → 导出 → 导出记录）。
///
/// 台账存在服务端（谁、何时、导出了哪个模块/单据、什么格式、多少行、
/// 什么文件名），所以**换设备也能看到同一份历史**；文件本身在导出
/// 那台设备上，这里只负责"翻旧账"和"本机还有这份文件时帮你打开"。
///
/// 为什么不做"服务端再下载一份"：导出文件从不过服务端（见 exportfmt.js
/// 头部），想再拿一份请回那台设备重新导一次 —— 把文件搬进服务端只会
/// 多一个"文件中转站"和一堆"导出一半失败"的分裂状态。
class ExportRecordsPage extends StatefulWidget {
  const ExportRecordsPage({super.key});

  @override
  State<ExportRecordsPage> createState() => _ExportRecordsPageState();
}

class _ExportRecordsPageState extends State<ExportRecordsPage> {
  static const int _limit = 30;

  final List<Map<String, dynamic>> _items = [];
  final ScrollController _scroll = ScrollController();

  int _total = 0;
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load(refresh: true);
    _scroll.addListener(() {
      if (_scroll.position.pixels >=
          _scroll.position.maxScrollExtent - 200) {
        _loadMore();
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _load({bool refresh = false}) async {
    if (refresh) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
    try {
      final res = await ImApi().exportRecords(limit: _limit, offset: 0);
      final items = (res['items'] as List?) ?? const [];
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(items.map((e) => Map<String, dynamic>.from(e as Map)));
        _total = (res['total'] as num?)?.toInt() ?? _items.length;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '读取导出记录失败：$e';
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _loading || _items.length >= _total) return;
    setState(() => _loadingMore = true);
    try {
      final res = await ImApi()
          .exportRecords(limit: _limit, offset: _items.length);
      final items = (res['items'] as List?) ?? const [];
      if (!mounted) return;
      setState(() {
        _items.addAll(items.map((e) => Map<String, dynamic>.from(e as Map)));
        _loadingMore = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _open(Map<String, dynamic> r) async {
    final name = (r['file_name'] ?? '').toString();
    if (name.isEmpty) return;
    try {
      final dir = await FileIo.dir();
      final f = File('${dir.path}${Platform.pathSeparator}${FileIo.safeName(name)}');
      if (!await f.exists()) {
        _toast('这份文件不在本机（导出是在哪台设备上做的，就得回哪台找）');
        return;
      }
      final err = await FileIo.open(f);
      if (err.isNotEmpty && mounted) _toast(err);
    } catch (e) {
      _toast('打开失败：$e');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bgElevated,
        title: const Text('导出记录', style: TextStyle(fontSize: 17)),
        actions: [
          IconButton(
            tooltip: '刷新',
            icon: const Icon(Icons.refresh, size: 20),
            onPressed: () => _load(refresh: true),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _errorView()
              : _items.isEmpty
                  ? _emptyView()
                  : RefreshIndicator(
                      onRefresh: () => _load(refresh: true),
                      child: ListView.separated(
                        controller: _scroll,
                        padding: const EdgeInsets.only(bottom: 24),
                        itemCount: _items.length + (_loadingMore ? 1 : 0),
                        separatorBuilder: (_, __) =>
                            Divider(height: 1, color: AppColors.divider),
                        itemBuilder: (_, i) {
                          if (i >= _items.length) {
                            return const Padding(
                              padding: EdgeInsets.all(16),
                              child: Center(
                                  child: SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2))),
                            );
                          }
                          return _tile(_items[i]);
                        },
                      ),
                    ),
    );
  }

  Widget _errorView() => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.cloud_off, size: 44, color: AppColors.textWeak),
              const SizedBox(height: 10),
              Text(_error!,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: AppColors.textSub)),
              const SizedBox(height: 14),
              OutlinedButton(
                  onPressed: () => _load(refresh: true),
                  child: const Text('重试')),
            ],
          ),
        ),
      );

  Widget _emptyView() => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.ios_share, size: 46, color: AppColors.textWeak),
              const SizedBox(height: 12),
              Text('还没有导出记录',
                  style: TextStyle(fontSize: 15, color: AppColors.textSub)),
              const SizedBox(height: 6),
              Text(
                '在扫码枪、简易盘点页点「导出」，这里会留下'
                '谁、何时、导出了什么、什么格式的台账。',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 12, color: AppColors.textWeak, height: 1.5),
              ),
            ],
          ),
        ),
      );

  Widget _tile(Map<String, dynamic> r) {
    final name = (r['file_name'] ?? '').toString();
    final module = (r['module_name'] ?? r['module'] ?? '').toString();
    final format = (r['format_name'] ?? '').toString();
    final rows = (r['rows'] as num?)?.toInt() ?? 0;
    final by = (r['username'] ?? '').toString();
    final ts = (r['created_at'] as num?)?.toInt() ?? 0;
    final docNo = (r['doc_no'] ?? '').toString();

    return ListTile(
      leading: Container(
        width: 38,
        height: 38,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.bgElevated,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppColors.divider),
        ),
        child: Text(
          (r['ext'] ?? '').toString().toUpperCase(),
          style: TextStyle(
              fontSize: 10, color: AppColors.textSub, fontWeight: FontWeight.w600),
        ),
      ),
      title: Text(name.isEmpty ? '（无文件名）' : name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14)),
      subtitle: Text(
        <String>[
          if (module.isNotEmpty) module,
          if (format.isNotEmpty) format,
          '$rows 行',
          if (docNo.isNotEmpty) docNo,
          if (by.isNotEmpty) '$by · ${TimeFmt.listStamp(ts)}',
        ].join('　'),
        maxLines: 2,
        style: TextStyle(fontSize: 11.5, color: AppColors.textWeak),
      ),
      trailing: Icon(Icons.open_in_new,
          size: 16, color: AppColors.textWeak),
      onTap: () => _open(r),
    );
  }
}
