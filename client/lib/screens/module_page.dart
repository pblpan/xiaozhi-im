import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../api.dart';
import '../core/module_schema.dart';
import '../core/theme.dart';
import '../widgets/module_renderer.dart';

/// 单个动态模块页面。
///
/// 打开时做两件事：
///   ① 重新拉一次模块定义（不吃列表页的旧缓存）—— 管理员刚改的立刻生效；
///   ② 若定义了 onLoad 取数动作，执行它，把结果作为 data 交给渲染器。
/// 取数失败不影响渲染：页面照样显示，只是列表/表格为空（配置问题不该变白屏）。
class ModulePage extends StatefulWidget {
  final ModuleDef initial;

  const ModulePage({super.key, required this.initial});

  @override
  State<ModulePage> createState() => _ModulePageState();
}

class _ModulePageState extends State<ModulePage> {
  late ModuleDef _def = widget.initial;
  Map<String, dynamic> _data = const {};
  bool _loading = true;
  String? _dataError;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    setState(() {
      _loading = true;
      _dataError = null;
    });

    // ① 取最新定义
    try {
      final r = await ImApi().clientModule(_def.moduleId);
      final m = r['module'];
      if (m != null) {
        final fresh = ModuleDef.fromJson(m);
        if (fresh.valid) _def = fresh;
      }
    } catch (_) {
      // 网络失败就用列表页带来的那份，页面仍然可用
    }

    // ② 取数
    await _loadData();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadData() async {
    final load = _def.onLoad;
    if (load == null) return;
    if (!load.canExecute) {
      // 客户端二次校验没过（例如 path 不是 /api/hooks/ 前缀）—— 直接不执行
      _dataError = '该页面配置的取数动作不合法，已跳过';
      return;
    }
    try {
      final r = await ImApi().hookCall(load.path!, method: load.method ?? 'GET');
      if (!mounted) return;
      setState(() {
        _data = _asMap(r);
        _dataError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _dataError = _friendlyDataError(e));
    }
  }

  static Map<String, dynamic> _asMap(dynamic r) {
    if (r is Map) return r.map((k, v) => MapEntry(k.toString(), v));
    if (r is List) return {'data': {'items': r}, 'items': r};
    return const {};
  }

  static String _friendlyDataError(Object e) {
    // 第三期才实现 /api/hooks/*，现在 404 属预期，别让用户以为坏了
    final s = e.toString();
    if (s.contains('404') || s.contains('请求失败 (HTTP 404)')) {
      return '取数接口尚未开放（第三期上线）';
    }
    return s;
  }

  Future<void> _onAction(ModuleAction a, Map<String, dynamic>? formData) async {
    // 表单提交：走模块自己的提交接口（服务端按自己的 schema 白名单清洗字段）
    if (formData != null) {
      await _submit(formData);
      return;
    }

    if (!a.known) {
      _toast('不支持的操作：${a.type}');
      return;
    }
    if (!a.canExecute) {
      _toast('该操作被安全策略拦截（${a.path ?? a.url ?? a.page ?? a.type}）');
      return;
    }

    switch (a.type) {
      case 'api':
      case 'submit':
        await _callHook(a);
        break;
      case 'copy':
        final text = a.text ?? ModuleData.of(_data, a.dataPath ?? '')?.toString() ?? '';
        if (text.isEmpty) {
          _toast('没有可复制的内容');
          return;
        }
        await Clipboard.setData(ClipboardData(text: text));
        _toast('已复制');
        break;
      case 'openUrl':
        final uri = Uri.tryParse(a.url!);
        if (uri == null) {
          _toast('链接无效');
          return;
        }
        if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
          _toast('无法打开链接');
        }
        break;
      case 'navigate':
        _navigate(a.page!);
        break;
      default:
        _toast('不支持的操作：${a.type}');
    }
  }

  Future<void> _callHook(ModuleAction a) async {
    try {
      final r = await ImApi().hookCall(a.path!, method: a.method ?? 'GET');
      if (!mounted) return;
      setState(() {
        // 合并回去而不是整体替换：页面里其它组件的数据不会被清掉
        _data = {..._data, ..._asMap(r)};
      });
      _toast('完成');
    } catch (e) {
      _toast(_friendlyDataError(e));
    }
  }

  Future<void> _submit(Map<String, dynamic> data) async {
    try {
      await ImApi().submitModule(_def.moduleId, data);
      if (!mounted) return;
      _toast('提交成功');
      await _loadData();
    } catch (e) {
      _toast('提交失败：$e');
    }
  }

  /// navigate 只能跳内置页面（白名单在 ModuleAction.canExecute 里已校验）
  void _navigate(String page) {
    switch (page) {
      case 'about':
        showAboutDialog(
          context: context,
          applicationName: '小智 IM',
          applicationVersion: 'v0.9.0',
        );
        break;
      case 'conversations':
      case 'contacts':
      case 'settings':
      case 'favorites':
      case 'profile':
        // 这些页面在主导航里，动态页是 push 进来的：直接退回去更符合直觉
        Navigator.of(context).maybePop();
        break;
      default:
        _toast('暂不支持跳转：$page');
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final sem = AppSemantic.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(_def.title),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _loading ? null : _boot,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: _loading && _def.body.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(14, 14, 14, 32),
              children: [
                if (_dataError != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _Notice(text: _dataError!, muted: sem.muted, border: sem.cardBorder),
                  ),
                ModuleRenderer(
                  body: _def.body,
                  data: _data,
                  onAction: _onAction,
                ),
              ],
            ),
    );
  }
}

class _Notice extends StatelessWidget {
  final String text;
  final Color muted;
  final Color border;

  const _Notice({required this.text, required this.muted, required this.border});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppRadii.sm),
        border: Border.all(color: border),
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 17, color: muted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: TextStyle(fontSize: 12.5, color: muted)),
          ),
        ],
      ),
    );
  }
}
