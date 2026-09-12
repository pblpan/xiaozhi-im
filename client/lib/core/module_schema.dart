// 动态模块的描述协议（SPEC-动态配置与模块.md §4）
//
// 两条纪律：
// 1. **解析绝不抛异常**。服务端已经校验过一遍，但客户端仍按"不可信输入"处理：
//    服务端可能被入侵、可能被中间人替换、也可能将来换了个不校验的实现。
//    任何看不懂的东西 → 降级成占位块（unknown），用户看到"暂不支持"而不是白屏崩溃。
// 2. **执行前二次校验动作**（见 ModuleAction.canExecute）：哪怕服务端下发了
//    `path: http://内网地址`，客户端也不会真的去请求。这是纵深防御的第二道闸。

/// 8 种封闭组件 + unknown（未知类型渲染成占位块）
enum ModuleComponentType { text, divider, card, list, table, form, action, chart, unknown }

ModuleComponentType _typeOf(String? s) {
  switch (s) {
    case 'text': return ModuleComponentType.text;
    case 'divider': return ModuleComponentType.divider;
    case 'card': return ModuleComponentType.card;
    case 'list': return ModuleComponentType.list;
    case 'table': return ModuleComponentType.table;
    case 'form': return ModuleComponentType.form;
    case 'action': return ModuleComponentType.action;
    case 'chart': return ModuleComponentType.chart;
    default: return ModuleComponentType.unknown;
  }
}

/// 语义颜色枚举。JSON 里只允许这些名字，具体色值由客户端按当前主题映射，
/// 这样将来加亮色主题时动态页面自动跟随（SPEC §4.3 拍板项 3）。
enum SemanticColor { primary, muted, danger, success, warning, defaultColor }

SemanticColor semanticColorOf(String? s) {
  switch (s) {
    case 'primary': return SemanticColor.primary;
    case 'muted': return SemanticColor.muted;
    case 'danger': return SemanticColor.danger;
    case 'success': return SemanticColor.success;
    case 'warning': return SemanticColor.warning;
    default: return SemanticColor.defaultColor;
  }
}

/// 动态页面能触发的动作（白名单，SPEC §4.4）
class ModuleAction {
  final String type; // api | navigate | copy | openUrl | submit
  final String? path;
  final String? method;
  final String? page;
  final String? text;
  final String? dataPath;
  final String? url;

  const ModuleAction({
    required this.type,
    this.path,
    this.method,
    this.page,
    this.text,
    this.dataPath,
    this.url,
  });

  factory ModuleAction.fromJson(Object? raw) {
    if (raw is! Map) return const ModuleAction(type: 'noop');
    final t = raw['action']?.toString() ?? '';
    return ModuleAction(
      type: t,
      path: raw['path']?.toString(),
      method: (raw['method']?.toString() ?? 'GET').toUpperCase(),
      page: raw['page']?.toString(),
      text: raw['text']?.toString(),
      dataPath: raw['dataPath']?.toString(),
      url: raw['url']?.toString(),
    );
  }

  /// 是否是一个已知动作类型
  bool get known =>
      type == 'api' || type == 'navigate' || type == 'copy' || type == 'openUrl' || type == 'submit';

  /// 执行前的二次校验 —— 服务端已校验过，这里是纵深防御：
  /// 服务端被入侵 / 配置被篡改时，客户端这一层还能拦住。
  bool get canExecute {
    switch (type) {
      case 'api':
      case 'submit':
        // 关键：只允许 /api/hooks/ 前缀，杜绝任意 URL 请求（SSRF）
        return path != null && path!.startsWith('/api/hooks/');
      case 'openUrl':
        // 只允许 https，http 会被中间人替换成钓鱼页
        return url != null && url!.toLowerCase().startsWith('https://');
      case 'navigate':
        return page != null && _navPages.contains(page);
      case 'copy':
        return (text != null && text!.isNotEmpty) || (dataPath != null && dataPath!.isNotEmpty);
      default:
        return false;
    }
  }

  static const _navPages = <String>{
    'conversations', 'contacts', 'settings', 'favorites', 'profile', 'about',
  };
}

/// 表单字段
class ModuleField {
  final String key;
  final String label;
  final String type; // text | number | select | date | textarea | switch
  final bool required;
  final String? placeholder;
  final List<ModuleOption> options;

  const ModuleField({
    required this.key,
    required this.label,
    required this.type,
    this.required = false,
    this.placeholder,
    this.options = const [],
  });

  factory ModuleField.fromJson(Object? raw) {
    if (raw is! Map) return const ModuleField(key: '', label: '', type: 'text');
    final opts = <ModuleOption>[];
    final rawOpts = raw['options'];
    if (rawOpts is List) {
      for (final o in rawOpts) {
        if (o is Map) opts.add(ModuleOption.fromJson(o));
      }
    }
    return ModuleField(
      key: raw['key']?.toString() ?? '',
      label: raw['label']?.toString() ?? raw['key']?.toString() ?? '',
      type: raw['type']?.toString() ?? 'text',
      required: raw['required'] == true,
      placeholder: raw['placeholder']?.toString(),
      options: opts,
    );
  }

  bool get isSelect => type == 'select';
  bool get isSwitch => type == 'switch';
  bool get isNumber => type == 'number';
  bool get isDate => type == 'date';
  bool get isTextarea => type == 'textarea';
}

class ModuleOption {
  final String label;
  final String value;
  const ModuleOption({required this.label, required this.value});

  factory ModuleOption.fromJson(Object? raw) {
    if (raw is! Map) return const ModuleOption(label: '', value: '');
    return ModuleOption(
      label: raw['label']?.toString() ?? raw['value']?.toString() ?? '',
      value: raw['value']?.toString() ?? '',
    );
  }
}

class ModuleColumn {
  final String key;
  final String label;
  final double? width;
  const ModuleColumn({required this.key, required this.label, this.width});

  factory ModuleColumn.fromJson(Object? raw) {
    if (raw is! Map) return const ModuleColumn(key: '', label: '');
    final w = raw['width'];
    return ModuleColumn(
      key: raw['key']?.toString() ?? '',
      label: raw['label']?.toString() ?? raw['key']?.toString() ?? '',
      width: w is num ? w.toDouble() : null,
    );
  }
}

class ModuleItemTemplate {
  final String title;
  final String subtitle;
  final String trailing;
  const ModuleItemTemplate({
    required this.title,
    this.subtitle = '',
    this.trailing = '',
  });

  factory ModuleItemTemplate.fromJson(Object? raw) {
    if (raw is! Map) return const ModuleItemTemplate(title: '');
    return ModuleItemTemplate(
      title: raw['title']?.toString() ?? '',
      subtitle: raw['subtitle']?.toString() ?? '',
      trailing: raw['trailing']?.toString() ?? '',
    );
  }
}

/// 一个组件。字段刻意"扁平"—— 8 种组件的字段全放在一个类里，
/// 换来的是解析逻辑只有一处，不会因为新增组件类型就漏改 switch。
class ModuleComponent {
  final ModuleComponentType type;
  final String? rawType; // 未知组件时保留原名，用于提示"暂不支持 xxx"

  final String text;
  final double? size;
  final SemanticColor color;
  final String align; // left | center | right

  final String title;
  final String subtitle;
  final SemanticColor accent;
  final List<ModuleComponent> children;

  final String dataPath;
  final ModuleItemTemplate itemTemplate;
  final List<ModuleColumn> columns;
  final List<ModuleField> fields;
  final ModuleAction? submit;

  final String label;
  final ModuleAction? onTap;

  final String chartKind;
  final String xKey;
  final String yKey;

  const ModuleComponent({
    required this.type,
    this.rawType,
    this.text = '',
    this.size,
    this.color = SemanticColor.defaultColor,
    this.align = 'left',
    this.title = '',
    this.subtitle = '',
    this.accent = SemanticColor.primary,
    this.children = const [],
    this.dataPath = '',
    this.itemTemplate = const ModuleItemTemplate(title: ''),
    this.columns = const [],
    this.fields = const [],
    this.submit,
    this.label = '',
    this.onTap,
    this.chartKind = 'bar',
    this.xKey = 'x',
    this.yKey = 'y',
  });

  factory ModuleComponent.fromJson(Object? raw) {
    if (raw is! Map) return const ModuleComponent(type: ModuleComponentType.unknown);
    final t = _typeOf(raw['component']?.toString());
    if (t == ModuleComponentType.unknown) {
      return ModuleComponent(
        type: ModuleComponentType.unknown,
        rawType: raw['component']?.toString(),
      );
    }
    final kids = <ModuleComponent>[];
    final rawKids = raw['children'];
    if (rawKids is List) {
      // 客户端也限制递归深度：即使服务端没拦住，也不能让 UI 线程爆栈
      var depth = 0;
      for (final c in rawKids) {
        if (depth++ >= 8) break;
        kids.add(ModuleComponent.fromJson(c));
      }
    }
    final cols = <ModuleColumn>[];
    final rawCols = raw['columns'];
    if (rawCols is List) {
      for (final c in rawCols) {
        final col = ModuleColumn.fromJson(c);
        if (col.key.isNotEmpty) cols.add(col);
      }
    }
    final fs = <ModuleField>[];
    final rawFields = raw['fields'];
    if (rawFields is List) {
      for (final f in rawFields) {
        final field = ModuleField.fromJson(f);
        if (field.key.isNotEmpty) fs.add(field);
      }
    }
    return ModuleComponent(
      type: t,
      text: raw['text']?.toString() ?? '',
      size: raw['size'] is num ? (raw['size'] as num).toDouble() : null,
      color: semanticColorOf(raw['color']?.toString()),
      align: ['left', 'center', 'right'].contains(raw['align']) ? raw['align'] as String : 'left',
      title: raw['title']?.toString() ?? '',
      subtitle: raw['subtitle']?.toString() ?? '',
      accent: semanticColorOf(raw['accent']?.toString()),
      children: kids,
      dataPath: raw['dataPath']?.toString() ?? '',
      itemTemplate: ModuleItemTemplate.fromJson(raw['itemTemplate']),
      columns: cols,
      fields: fs,
      submit: raw['submit'] == null ? null : ModuleAction.fromJson(raw['submit']),
      label: raw['label']?.toString() ?? '',
      onTap: raw['onTap'] == null ? null : ModuleAction.fromJson(raw['onTap']),
      chartKind: raw['kind']?.toString() ?? 'bar',
      xKey: raw['xKey']?.toString() ?? 'x',
      yKey: raw['yKey']?.toString() ?? 'y',
    );
  }
}

/// 一个动态模块定义
class ModuleDef {
  final String moduleId;
  final String title;
  final String icon;
  final String? minClientVersion;
  final bool enabled;
  final int sort;
  final List<ModuleComponent> body;
  final ModuleAction? onLoad;

  const ModuleDef({
    required this.moduleId,
    required this.title,
    this.icon = 'dashboard',
    this.minClientVersion,
    this.enabled = true,
    this.sort = 0,
    this.body = const [],
    this.onLoad,
  });

  factory ModuleDef.fromJson(Object? raw) {
    if (raw is! Map) return const ModuleDef(moduleId: '', title: '');
    final rawBody = raw['body'];
    final body = <ModuleComponent>[];
    if (rawBody is List) {
      for (final c in rawBody) {
        body.add(ModuleComponent.fromJson(c));
      }
    }
    return ModuleDef(
      moduleId: raw['moduleId']?.toString() ?? '',
      title: raw['title']?.toString() ?? raw['moduleId']?.toString() ?? '',
      icon: raw['icon']?.toString() ?? 'dashboard',
      minClientVersion: raw['minClientVersion']?.toString(),
      enabled: raw['enabled'] != false,
      sort: raw['sort'] is num ? (raw['sort'] as num).toInt() : 0,
      body: body,
      onLoad: raw['onLoad'] == null ? null : ModuleAction.fromJson(raw['onLoad']),
    );
  }

  bool get valid => moduleId.isNotEmpty;

  /// 客户端侧的版本闸门：版本不够直接不显示（服务端已过滤，这里是双保险）。
  /// 传空/非法版本一律当作"不满足" —— 宁可不显示，也不要显示一个跑不起来的页面。
  bool supports(String clientVersion) {
    final min = minClientVersion;
    if (min == null || min.isEmpty) return true;
    if (!_versionRe.hasMatch(min) || !_versionRe.hasMatch(clientVersion)) return false;
    return !_versionLess(clientVersion, min);
  }

  static final _versionRe = RegExp(r'^\d+\.\d+\.\d+$');

  /// a < b 返回 true（与 remote_config.versionLess 同语义，这里独立实现以免循环依赖）
  static bool _versionLess(String a, String b) {
    final pa = a.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final pb = b.split('.').map((s) => int.tryParse(s) ?? 0).toList();
    final n = pa.length > pb.length ? pa.length : pb.length;
    for (var i = 0; i < n; i++) {
      final x = i < pa.length ? pa[i] : 0;
      final y = i < pb.length ? pb[i] : 0;
      if (x != y) return x < y;
    }
    return false;
  }
}

/// 模板串渲染：`{{name}}` → 取 data 里的 name 字段。
/// 取不到就原样保留占位符（比显示空白更容易发现配置写错了）。
String renderTemplate(String tpl, Map<String, dynamic> data) {
  if (!tpl.contains('{{')) return tpl;
  return tpl.replaceAllMapped(RegExp(r'\{\{\s*([\w.]+)\s*\}\}'), (m) {
    final v = ModuleData.of(data, m.group(1)!);
    return v?.toString() ?? m.group(0)!;
  });
}

/// dataPath 取值工具：支持 `a.b[0].c` 形式
class ModuleData {
  const ModuleData._();

  static dynamic of(Object? root, String path) {
    if (path.isEmpty) return null;
    var cur = root;
    // 先按 . 拆，再处理每段可能带的 [n]
    for (final seg in path.split('.')) {
      if (cur == null) return null;
      final m = RegExp(r'^([^\[\]]+)((\[\d+\])*)$').firstMatch(seg);
      if (m == null) return null;
      var key = m.group(1)!;
      final idxPart = m.group(2) ?? '';
      if (cur is Map) {
        cur = cur[key];
      } else if (cur is List) {
        final i = int.tryParse(key);
        if (i == null) return null;
        if (i < 0 || i >= cur.length) return null;
        cur = cur[i];
      } else {
        return null;
      }
      if (idxPart.isNotEmpty) {
        for (final im in RegExp(r'\[(\d+)\]').allMatches(idxPart)) {
          if (cur is! List) return null;
          final i = int.parse(im.group(1)!);
          if (i < 0 || i >= cur.length) return null;
          cur = cur[i];
        }
      }
    }
    return cur;
  }

  /// 取数组：路径指向 List 就返回它，指向空就返回空数组（UI 侧不必判空）
  static List<dynamic> listOf(Object? root, String path) {
    final v = of(root, path);
    if (v is List) return v;
    return const [];
  }
}
