import 'package:flutter/material.dart';

import '../api.dart';
import '../core/app_version.dart';
import '../core/module_schema.dart';
import '../core/theme.dart';
import '../widgets/module_renderer.dart';
import 'module_page.dart';

/// 动态模块列表（「应用」入口）。
///
/// 列表本身也是"下发"的：服务端按角色/用户/客户端版本过滤后才给这里，
/// 客户端不做任何筛选逻辑（SPEC 拍板项 1：数据服务端算好）。
class ModuleHubPage extends StatefulWidget {
  const ModuleHubPage({super.key});

  @override
  State<ModuleHubPage> createState() => _ModuleHubPageState();
}

class _ModuleHubPageState extends State<ModuleHubPage> {
  bool _loading = true;
  String? _error;
  List<ModuleDef> _modules = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final raw = await ImApi().clientModules();
      final list = raw.map(ModuleDef.fromJson).where((m) => m.valid).toList()
        ..sort((a, b) => a.sort == b.sort ? a.title.compareTo(b.title) : a.sort - b.sort);
      if (!mounted) return;
      setState(() {
        // 客户端侧再卡一次版本闸门：服务端过滤过，但客户端不能假设它一定对
        _modules = list.where((m) => m.supports(kAppVersion)).toList();
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('应用'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: RefreshIndicator(onRefresh: _load, child: _body()),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _hint(
        icon: Icons.cloud_off,
        title: '拿不到应用列表',
        desc: _error!,
        action: TextButton(onPressed: _load, child: const Text('重试')),
      );
    }
    if (_modules.isEmpty) {
      return _hint(
        icon: Icons.widgets_outlined,
        title: '还没有应用',
        desc: '管理员在管理台发布动态模块后，这里会出现入口。\n'
            '无需升级客户端，下拉即可刷新。',
      );
    }
    final sem = AppSemantic.of(context);
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      itemCount: _modules.length,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (c, i) {
        final m = _modules[i];
        return InkWell(
          borderRadius: BorderRadius.circular(AppRadii.md),
          onTap: () async {
            await Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => ModulePage(initial: m)),
            );
            if (mounted) _load();
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            decoration: BoxDecoration(
              color: sem.cardBg,
              borderRadius: BorderRadius.circular(AppRadii.md),
              border: Border.all(color: sem.cardBorder),
            ),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    gradient: AppTheme.brandGradient,
                    borderRadius: BorderRadius.circular(AppRadii.sm),
                  ),
                  child: Icon(moduleIcon(m.icon), color: Colors.white, size: 21),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(m.title,
                          style: const TextStyle(
                              fontSize: 15.5, fontWeight: FontWeight.w600)),
                      const SizedBox(height: 2),
                      Text('${m.body.length} 个内容块',
                          style: TextStyle(fontSize: 12.5, color: sem.muted)),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: sem.muted),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _hint({
    required IconData icon,
    required String title,
    required String desc,
    Widget? action,
  }) {
    final sem = AppSemantic.of(context);
    // 用 ListView 包一层，保证下拉刷新在空状态下也能用
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 90),
          child: Column(
            children: [
              Icon(icon, size: 44, color: sem.muted),
              const SizedBox(height: 14),
              Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 40),
                child: Text(desc,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, height: 1.6, color: sem.muted)),
              ),
              if (action != null) ...[const SizedBox(height: 12), action],
            ],
          ),
        ),
      ],
    );
  }
}
