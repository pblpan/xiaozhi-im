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

  /// 表单动态下拉的选项（字段 key → 选项）。2026-10-18 排班三件套：
  /// 班次/员工这种"会变的清单"不能写死在模块定义里，由页面按字段的
  /// optionsFrom 现取，渲染器只负责画（它不该碰网络）。
  Map<String, List<ModuleOption>> _dynOptions = const {};

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
    // ③ 取表单动态下拉的选项（没有动态字段就是空转，不会发请求）
    await _loadOptions();
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

  /// 拉表单动态下拉的选项。
  ///
  /// 同一个 optionsFrom 路径只取一次（多个字段可能共用一份班次/成员清单），
  /// 各字段再按自己的 optionsPath / optionLabel / optionValue 从同一份
  /// 响应里取 —— 取 N 次的结果不只是浪费，是 N 次可能拿到不一致的清单。
  Future<void> _loadOptions() async {
    final fields = <ModuleField>[];
    void scan(List<ModuleComponent> comps) {
      for (final c in comps) {
        if (c.type == ModuleComponentType.form) fields.addAll(c.fields);
        // 表单可能嵌在 card 里（卡片分组是常见排法），不递归就会漏
        scan(c.children);
      }
    }

    scan(_def.body);
    final dyn = fields.where((f) => f.hasDynamicOptions).toList();
    if (dyn.isEmpty) {
      if (_dynOptions.isNotEmpty && mounted) setState(() => _dynOptions = const {});
      return;
    }

    // 按路径去重取数
    final byPath = <String, dynamic>{};
    for (final f in dyn) {
      final p = f.optionsFrom!;
      if (byPath.containsKey(p)) continue;
      try {
        byPath[p] = await ImApi().hookCall(p, method: 'GET');
      } catch (_) {
        byPath[p] = null; // 失败也记一笔：下面回落到静态选项，且不会重试轰炸
      }
    }

    final out = <String, List<ModuleOption>>{};
    for (final f in dyn) {
      final resp = byPath[f.optionsFrom!];
      final list = resp == null ? const <dynamic>[] : ModuleData.listOf(resp, f.optionsPath);
      final opts = <ModuleOption>[];
      for (final item in list) {
        if (item is! Map) continue;
        final label = item[f.optionLabel]?.toString() ?? '';
        final value = item[f.optionValue]?.toString() ?? '';
        if (value.isEmpty) continue; // 空值项选了也提交不上，不如不显示
        opts.add(ModuleOption(label: label.isEmpty ? value : label, value: value));
      }
      if (opts.isNotEmpty) out[f.key] = opts;
    }
    if (mounted) setState(() => _dynOptions = out);
  }

  /// 列表 / 表格 / 图表空着时该说什么。
  ///
  /// 🔴 空态一律写「暂无数据」会把两种完全不同的情况混成一句：
  ///    ① 管理员压根没配数据来源（**配置没做完**，得有人去补）；
  ///    ② 配了，这份数据现在真的是空的（**正常业务状态**，不用管）。
  ///    员工看到同一句话不知道该不该报障，管理员也从没人提醒他去补。
  ///    取数失败则交给 _dataError 那条提示（它已经能说清是超时还是 403），
  ///    这里不再叠一句，避免同一件事说两遍。
  bool get _truncated => _data['truncated'] == true;

  /// 实际显示的行数：取数接口统一回 { data:{ rows, total } } 这个形状
  int get _shownRows {
    final d = _data['data'];
    final rows = d is Map ? d['rows'] : null;
    return rows is List ? rows.length : 0;
  }

  int get _totalRows {
    final d = _data['data'];
    final t = d is Map ? d['total'] : null;
    return t is num ? t.toInt() : _shownRows;
  }

  String? get _emptyHint {
    if (_dataError != null) return null;
    if (_def.onLoad == null) {
      return '这个页面还没接数据来源 —— 请管理员到管理台「动态模块」里选一份数据';
    }
    if (!_def.onLoad!.canExecute) return '这个页面配的取数地址不合法，已跳过';
    return null;
  }

  static Map<String, dynamic> _asMap(dynamic r) {
    if (r is Map) return r.map((k, v) => MapEntry(k.toString(), v));
    if (r is List) return {'data': {'items': r}, 'items': r};
    return const {};
  }

  static String _friendlyDataError(Object e) {
    // 这里的 404 是**上游自己**回的（服务端把上游状态原样透传），
    // 不是"这条链路还没做" —— 网关侧的问题（没登记/停用/超时/连不上）都由服务端
    // 归成 502 并带一句能看懂的中文，走下面的原样透出分支。
    final s = e.toString();
    if (s.contains('404')) {
      return '上游没有这个接口（地址或子路径可能写错了，去管理台「上游接口」试跑一下）';
    }
    return s;
  }

  Future<void> _onAction(ModuleAction a, Map<String, dynamic>? formData) async {
    // 表单提交两条路（2026-10-18 排班三件套）：
    //   ① form.submit 配成了 api 动作（指向 /api/hooks/...）→ "表单即录入"：
    //      数据直接进业务表（排班表），提交完刷新页面数据；
    //   ② 没配 / 配的不是 api → 老行为：submitModule 只留痕
    //      （module_submissions），班表那种"要真写进业务表"的场景不能走它，
    //      否则就是"提示提交成功、班表什么都没变"的假成功。
    if (formData != null) {
      if (a.type == 'api' && a.canExecute) {
        await _callHook(a, body: formData);
        return;
      }
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

  Future<void> _callHook(ModuleAction a, {Map<String, dynamic>? body}) async {
    try {
      final r = await ImApi().hookCall(a.path!, method: a.method ?? 'GET', body: body);
      if (!mounted) return;
      // 只有取数型调用才把响应并回页面数据：写入型调用的响应是
      // { ok, source, ms, result } 这种回执，并进去只会污染 data，
      // 而它真正的作用是触发下面那次刷新
      if (body == null) {
        setState(() {
          // 合并回去而不是整体替换：页面里其它组件的数据不会被清掉
          _data = {..._data, ..._asMap(r)};
        });
      }
      // 写入型调用（表单提交）成功后必须刷新取数：不刷新的话表格还是旧的，
      // 用户会以为"没写进去"再提交一遍 —— 排班是 upsert 所以看不出错，
      // 但换任何非幂等的业务就是重复数据
      if (body != null) await _loadData();
      _toast(body == null ? '完成' : '已提交');
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
                // 取回来的行被服务端截断时必须说清：一张"看起来只有 200 行"的表，
                // 会让人以为库里就这么多 —— 这比报错更误导
                if (_truncated)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _Notice(
                      text: '这份数据较多，只显示了前 ${_shownRows} 行（共 ${_totalRows} 行）。'
                          '要看全部请到管理台导出。',
                      muted: sem.muted,
                      border: sem.cardBorder,
                    ),
                  ),
                ModuleRenderer(
                  body: _def.body,
                  data: _data,
                  onAction: _onAction,
                  emptyHint: _emptyHint,
                  dynamicOptions: _dynOptions,
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
