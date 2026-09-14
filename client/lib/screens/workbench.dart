import 'package:flutter/material.dart';

import '../api.dart';
import '../core/app_version.dart';
import '../core/apps.dart';
import '../core/module_schema.dart';
import '../core/theme.dart';
import '../widgets/module_renderer.dart';
import 'module_page.dart';

/// 工作台（应用中心）。
///
/// 这是模型的"统一入口面"：钉钉/企微/飞书都把它叫工作台。它把两类应用放在一起：
///
///   「工作」分组   内置应用（考勤打卡 / 我的申请 / 组织通讯录）—— 随安装包发布
///   「自定义」分组 动态模块（管理台拼 JSON 下发）—— 不重装就能长出功能
///
/// **列表本身完全由服务端决定**：哪些应用可见、什么顺序、带不带角标，
/// 服务端算好再下发（SPEC 拍板项 1）。客户端只做两件事：
///   ① 认识的内置应用 → 打开对应页面；
///   ② 不认识的 id → 不显示（服务端上了新应用而客户端还没升级时，少一个图标而已）。
class WorkbenchPage extends StatefulWidget {
  const WorkbenchPage({super.key});

  @override
  State<WorkbenchPage> createState() => _WorkbenchPageState();
}

class _WorkbenchPageState extends State<WorkbenchPage> {
  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _apps = const [];

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
      final r = await ImApi().clientApps();
      final raw = (r['apps'] as List?) ?? const [];
      final list = <Map<String, dynamic>>[];
      for (final e in raw) {
        if (e is! Map) continue;
        final m = Map<String, dynamic>.from(e);
        final kind = (m['kind'] ?? '') as String;
        final id = (m['id'] ?? '') as String;
        if (id.isEmpty) continue;
        // 不认识的**内置**应用直接跳过：服务端可能已经上了新应用，
        // 而这个客户端还是旧版本 —— 少一个图标，绝不白屏、绝不报错。
        if (kind == 'builtin' && !isKnownBuiltinApp(id)) continue;
        // 未知 kind（比如服务端将来加了新类型）同样跳过，不猜
        if (kind != 'builtin' && kind != 'dynamic') continue;
        // 动态模块的版本闸门（双保险）：服务端按 ?clientVersion= 过滤过，
        // 但客户端不假设它一定对 —— 版本不够的入口宁可不显示，
        // 也不要让人点进去对着跑不起来的页面反复点。
        if (kind == 'dynamic' &&
            !clientSatisfiesVersion(m['minVersion']?.toString(), kAppVersion)) {
          continue;
        }
        list.add(m);
      }
      if (!mounted) return;
      setState(() {
        _apps = list;
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

  List<Map<String, dynamic>> _group(String g) =>
      _apps.where((a) => (a['group'] ?? 'work') == g).toList();

  Future<void> _open(Map<String, dynamic> app) async {
    final kind = app['kind'] as String;
    final id = app['id'] as String;
    try {
      if (kind == 'builtin') {
        final page = builtinAppPage(id);
        if (page == null) {
          _toast('当前客户端版本不支持「${app['title']}」，请升级客户端后再试');
          return;
        }
        await Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
      } else {
        // 动态模块：打开时取最新定义（不吃列表里的旧缓存）
        final r = await ImApi().clientModule(id);
        final def = ModuleDef.fromJson(r['module']);
        if (!def.valid) {
          _toast('该应用的定义无效，已跳过');
          return;
        }
        if (!mounted) return;
        await Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => ModulePage(initial: def)));
      }
    } catch (e) {
      _toast('打不开该应用：$e');
    }
    // 回来刷新角标（比如刚打完卡，"待打卡"就该消失）
    if (mounted) _load();
  }

  void _toast(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(s), duration: const Duration(seconds: 3)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('工作台'),
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
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return _hint(
        icon: Icons.cloud_off,
        title: '拿不到应用列表',
        desc: _error!,
        action: TextButton(onPressed: _load, child: const Text('重试')),
      );
    }
    if (_apps.isEmpty) {
      return _hint(
        icon: Icons.widgets_outlined,
        title: '还没有应用',
        desc: '管理员在管理台开启工作模式、建好组织后，这里会出现「考勤打卡」等应用；\n'
            '他在「动态模块」里发布的自定义应用也会出现在这里。\n'
            '无需升级客户端，下拉即可刷新。',
      );
    }

    final work = _group('work');
    final custom = _group('custom');
    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 28),
      children: [
        if (work.isNotEmpty) ...[
          _sectionTitle('工作'),
          _grid(work),
        ],
        if (custom.isNotEmpty) ...[
          SizedBox(height: work.isNotEmpty ? 22 : 0),
          _sectionTitle('自定义应用'),
          ...custom.map(_row),
        ],
      ],
    );
  }

  Widget _sectionTitle(String t) {
    final sem = AppSemantic.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10, left: 2),
      child: Text(t,
          style: TextStyle(
              fontSize: 13, fontWeight: FontWeight.w600, color: sem.muted, letterSpacing: 0.5)),
    );
  }

  Widget _grid(List<Map<String, dynamic>> apps) {
    return LayoutBuilder(builder: (ctx, c) {
      final w = c.maxWidth;
      final cols = w >= 940 ? 4 : (w >= 660 ? 3 : 2);
      return GridView.count(
        crossAxisCount: cols,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 1.25,
        children: apps.map(_card).toList(),
      );
    });
  }

  Widget _card(Map<String, dynamic> app) {
    final sem = AppSemantic.of(context);
    final badge = (app['badge'] ?? '').toString();
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadii.md),
      onTap: () => _open(app),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: sem.cardBg,
          borderRadius: BorderRadius.circular(AppRadii.md),
          border: Border.all(color: sem.cardBorder),
        ),
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    gradient: AppTheme.brandGradient,
                    borderRadius: BorderRadius.circular(AppRadii.sm),
                  ),
                  child: Icon(moduleIcon(app['icon']?.toString() ?? ''),
                      color: Colors.white, size: 22),
                ),
                const Spacer(),
                Text(app['title']?.toString() ?? '应用',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                const SizedBox(height: 3),
                Text(
                  (app['desc']?.toString().isNotEmpty ?? false)
                      ? app['desc'].toString()
                      : '自定义应用',
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11.5, height: 1.4, color: sem.muted),
                ),
              ],
            ),
            if (badge.isNotEmpty)
              Positioned(
                right: 0,
                top: 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.danger,
                    borderRadius: BorderRadius.circular(AppRadii.pill),
                  ),
                  child: Text(badge,
                      style: const TextStyle(
                          fontSize: 10.5, color: Colors.white, fontWeight: FontWeight.w600)),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _row(Map<String, dynamic> app) {
    final sem = AppSemantic.of(context);
    final badge = (app['badge'] ?? '').toString();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadii.md),
        onTap: () => _open(app),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          decoration: BoxDecoration(
            color: sem.cardBg,
            borderRadius: BorderRadius.circular(AppRadii.md),
            border: Border.all(color: sem.cardBorder),
          ),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  gradient: AppTheme.brandGradient,
                  borderRadius: BorderRadius.circular(AppRadii.sm),
                ),
                child: Icon(moduleIcon(app['icon']?.toString() ?? ''),
                    color: Colors.white, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(app['title']?.toString() ?? '应用',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              ),
              if (badge.isNotEmpty) ...[
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.danger,
                    borderRadius: BorderRadius.circular(AppRadii.pill),
                  ),
                  child: Text(badge,
                      style: const TextStyle(
                          fontSize: 10.5, color: Colors.white, fontWeight: FontWeight.w600)),
                ),
                const SizedBox(width: 8),
              ],
              Icon(Icons.chevron_right, color: sem.muted),
            ],
          ),
        ),
      ),
    );
  }

  Widget _hint({
    required IconData icon,
    required String title,
    required String desc,
    Widget? action,
  }) {
    final sem = AppSemantic.of(context);
    // 用 ListView 包一层，保证空状态下也能下拉刷新
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
                padding: const EdgeInsets.symmetric(horizontal: 36),
                child: Text(desc,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 13, height: 1.7, color: sem.muted)),
              ),
              if (action != null) ...[const SizedBox(height: 12), action],
            ],
          ),
        ),
      ],
    );
  }
}
