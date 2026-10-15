import 'dart:async';

import 'package:flutter/material.dart';

import '../api.dart';
import '../core/app_version.dart';
import '../core/apps.dart';
import '../core/module_schema.dart';
import '../core/session_manager.dart';
import '../core/theme.dart';
import '../core/config.dart';
import '../core/workbench_cache.dart';
import '../widgets/module_renderer.dart';
import 'module_page.dart';

/// 工作台（应用中心）。
///
/// 对齐钉钉 / 企业微信 / 飞书的地方，以及**这里刻意不改的地方**：
///
///   ① **顶部公告位** —— 那三家的公告都在工作台第一眼。它是"必须读到"的位置，
///      不是群消息的副本。服务端下几条、显示哪几条由管理台决定（见 appnotice.js）。
///   ② **搜索框** —— 应用一多，"翻格子"就变成体力活。搜索只匹配名称，
///      够用了：按 desc 全文搜会让"搜一个字跳出五个看不懂的东西"。
///   ③ **一排彩色圆形图标** —— 那三家的图标都不是同一个灰方块，每个应用自己的
///      颜色。一排同色图标，员工扫一眼分不出哪个是打卡、哪个是盘点。
///      颜色来自服务端下发的 `color`（管理台可改，出厂色在 server/src/apps.js）。
///   ④ **分组标题由服务端给** —— 组名写死在客户端会让管理员改不了，
///      于是工作台永远像别人家的默认模板。
///
/// ⚠️ **列表本身完全由服务端决定**：哪些应用可见、什么顺序、带不带角标，
/// 服务端算好再下发。客户端只做两件事：
///   ① 认识的内置应用 → 打开对应页面；
///   ② 不认识的 id → 不显示（服务端上了新应用而客户端还没升级时，少一个图标而已）。
///
/// 🔴 布局约定：所有分组**一律走同一套网格**。曾经「工作」是网格、「自定义应用」
/// 是列表行，两种排版并存 —— 结果管理员把某个动态模块挪进「工作」组后，
/// 它在手机上的样子和隔壁的考勤完全不一样，像两套产品。
/// 按关键词过滤应用。**只匹配名称，不匹配 desc** ——
/// desc 是"起疑心"的短句，按它搜会跳出一堆看不懂的结果。
/// 关键词为空时原样返回（不是返回一个空列表）。
List<Map<String, dynamic>> workbenchFilter(
  List<Map<String, dynamic>> apps,
  String kw,
) {
  if (kw.isEmpty) return apps;
  return apps
      .where((a) => (a['title']?.toString() ?? '').toLowerCase().contains(kw))
      .toList();
}

/// 把应用按分组归堆，组序**按服务端下发的 sort**（管理员在管理台拖的顺序）。
/// 返回 `[{'label': 组名, '_items': [...], '_sort': 序号}]`。
///
/// 两条刻意的行为：
///   · 空组（管理员把最后一个应用挪走了）不显示 —— 留一个空标题最像坏掉；
///   · 应用里出现、但分组清单里没有的 key（管理员刚建的组，这个客户端还没刷新到）
///     也兜底显示，组名先用 key 本身 —— 比整个消失好。
List<Map<String, Object?>> workbenchSections({
  required List<Map<String, dynamic>> apps,
  required List<dynamic> groups,
  String fallbackGroup = 'work',
}) {
  final out = <Map<String, Object?>>[];
  final used = <String>{};
  for (final g in groups) {
    if (g is! Map) continue;
    final key = (g['key'] ?? '').toString();
    final items = apps
        .where((a) => (a['group'] ?? fallbackGroup) == key)
        .toList();
    if (items.isEmpty) continue;
    used.add(key);
    out.add({
      'label': g['label']?.toString() ?? key,
      '_items': items,
      // 🔴 组序真正的判据是**服务端下发的 sort**，不是清单里的下标。
      //    用 indexOf 的话，只要服务端下发顺序没跟 sort 走一遍（比如某个
      //    中间层重新排序、或者将来管理台的排序存丢了），管理员拖的顺序就
      //    悄悄失效 —— 而且怎么测都"对"，因为两边的顺序恰好一致。
      //    只有真的下发了一个 sort 与位置不符的数据，才会暴露。
      '_sort': (g['sort'] is int) ? g['sort'] as int : groups.indexOf(g),
    });
  }
  // 组外应用兜底
  for (final a in apps) {
    final key = (a['group'] ?? fallbackGroup).toString();
    if (used.contains(key)) continue;
    out.add({
      'label': key,
      '_items': apps
          .where((x) => (x['group'] ?? fallbackGroup) == key)
          .toList(),
      '_sort': 999,
    });
  }
  out.sort((x, y) => (x['_sort'] as int).compareTo(y['_sort'] as int));
  return out;
}

class WorkbenchPage extends StatefulWidget {
  const WorkbenchPage({super.key});

  @override
  State<WorkbenchPage> createState() => _WorkbenchPageState();
}

/// 工作台网格的列数。
///
/// 手机上一律 **4 列** —— 3 列格子大得像卡片、2 列又太宽，
/// 4 列才是企微/飞书那个"一排四个、一眼扫完"的感觉。
/// 宽屏（桌面）跟着放宽，但**绝不少于 4**（窄的时候收窄格子，不要收列数）。
int workbenchColumns(double width) {
  if (width >= 1100) return 8;
  if (width >= 820) return 6;
  if (width >= 600) return 5;
  return 4;
}

/// 应用图标底色：优先服务端下发的 `color`（出厂色在 server/src/apps.js，
/// 管理台可覆盖）；没有就用品牌色 —— 注意是"所有应用一个色"，
/// 而不是"所有应用一个色块 + 一个图标"，后者还是分不清谁是谁。
Color workbenchAppColor(Map<String, dynamic> app) {
  final s = app['color']?.toString() ?? '';
  if (s.length == 7 && s.startsWith('#')) {
    try {
      // #RRGGBB → Color(0xFFRRGGBB)（int.parse 认不了带 # 的串，先截掉）
      return Color(int.parse(s.substring(1), radix: 16) + 0xFF000000);
    } catch (_) {
      // 解析不了就走品牌色 —— 比"图标变成一个黑色方块"强
    }
  }
  return AppColors.brand;
}

class _WorkbenchPageState extends State<WorkbenchPage> {
  bool _loading = true;
  String? _error;
  /// 网络刷新失败、正在显示缓存数据时的提示（龙哥 2026-10-15 要求：
  /// 外网差也要能进不需要联网的应用，但不能让人以为看到的就是最新）
  bool _stale = false;
  List<Map<String, dynamic>> _apps = const [];
  List<Map<String, dynamic>> _groups = const [];
  List<Map<String, dynamic>> _notices = const [];
  final TextEditingController _q = TextEditingController();
  String _kw = '';

  /// 当前企业（profile）的缓存键。多企业各一份缓存，切过去立刻有画面。
  String get _profileKey => SessionManager.instance.active?.id ?? 'default';

  @override
  void initState() {
    super.initState();
    _q.addListener(() {
      final v = _q.text.trim().toLowerCase();
      if (v != _kw) setState(() => _kw = v);
    });
    // 切换企业（整域切换）→ 重新拉取这台服务器的应用/分组/公告
    SessionManager.instance.domainVersion.addListener(_onDomain);
    // 缓存优先：先把上次的清单画出来，再去网络刷新。
    // 外网再差，不需要联网的应用（盘点/商档查询这类本地功能）也点得进去。
    unawaited(_restoreThenRefresh());
  }

  @override
  void dispose() {
    SessionManager.instance.domainVersion.removeListener(_onDomain);
    _q.dispose();
    super.dispose();
  }

  /// 切到另一家企业时，重新拉取工作台数据。
  void _onDomain() {
    if (!mounted) return;
    _load();
  }

  /// 先读缓存渲染，再后台刷新。首次无缓存时行为与原来一致（转圈等网络）。
  Future<void> _restoreThenRefresh() async {
    final cached = await WorkbenchCache.instance.read(_profileKey);
    if (!mounted) return;
    if (cached != null) {
      final apps = ((cached['apps'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      if (apps.isNotEmpty) {
        setState(() {
          _apps = apps;
          _groups = ((cached['groups'] as List?) ?? const [])
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
          _notices = ((cached['notices'] as List?) ?? const [])
              .whereType<Map>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
          _loading = false;
          _error = null;
        });
      }
    }
    await _load();
  }

  Future<void> _load() async {
    // 已有清单时不显示整页转圈（会把已渲染的内容挡住，白闪一下很吵）；
    // 只有首次（没有缓存）才转圈。
    final hadList = _apps.isNotEmpty;
    if (!hadList) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }
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
      final groups = ((r['groups'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      final notices = ((r['notices'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      setState(() {
        _apps = list;
        // 分组清单跟着下发，客户端不写死组名（管理员可以在管理台改）
        _groups = groups;
        // 公告：没配就是空列表，客户端不编一条默认的出来
        _notices = notices;
        _loading = false;
        _error = null;
        _stale = false;
      });
      await WorkbenchCache.instance.write(
        _profileKey,
        apps: list,
        groups: groups,
        notices: notices,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        if (_apps.isNotEmpty) {
          // 有缓存：继续显示缓存，只置 stale 提示，不弹错误页
          _stale = true;
          _error = null;
        } else {
          _error = e.toString();
        }
      });
    }
  }

  List<Map<String, dynamic>> get _shown => workbenchFilter(_apps, _kw);

  List<Map<String, Object?>> get _sections => workbenchSections(
        apps: _shown,
        groups: _groups,
      );

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

    final sections = _sections;
    return CustomScrollView(
      slivers: [
        // 缓存提示条：网络刷新失败但正在显示上次的清单（龙哥 2026-10-15：
        // 外网差也要能进本地应用，但不能让人以为缓存就是最新数据）
        if (_stale)
          SliverToBoxAdapter(
            child: Container(
              width: double.infinity,
              margin: const EdgeInsets.fromLTRB(14, 10, 14, 0),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: AppSemantic.of(context).warning.withOpacity(0.12),
                borderRadius: BorderRadius.circular(AppRadii.md),
              ),
              child: Row(children: [
                Icon(Icons.cloud_off_rounded,
                    size: 15, color: AppSemantic.of(context).warning),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text('网络不稳，显示的是上次的清单，下拉可重试',
                      style: TextStyle(fontSize: 12)),
                ),
              ]),
            ),
          ),
        // 顶部公告位
        if (_notices.isNotEmpty) _noticeSliver(),
        // 搜索框（应用多的时候"翻格子"是体力活，企微/飞书都有这一条）
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: TextField(
              controller: _q,
              style: const TextStyle(fontSize: 14),
              decoration: InputDecoration(
                hintText: '搜索应用',
                prefixIcon: const Icon(Icons.search, size: 20),
                isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadii.md)),
                enabledBorder:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadii.md)),
                focusedBorder:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(AppRadii.md)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              ),
            ),
          ),
        ),
        if (_kw.isNotEmpty) ...[
          // 搜到什么直接平铺出来，不再显示分组标题 ——
          // "刚搜到的是哪个组的"在这个时刻是干扰，不是信息。
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 2, 14, 8),
              child: Text(
                '搜到 ${_shown.length} 个应用（"$_kw"）',
                style: TextStyle(fontSize: 12.5, color: AppSemantic.of(context).muted),
              ),
            ),
          ),
          SliverToBoxAdapter(child: _grid(_shown)),
        ] else ...[
          // 🔴 必须是**一个循环里「标题 + 它自己的网格」交替出**，不能写成
          //    两次 sections.map（先把所有标题铺完、再铺所有网格）。
          //
          // 2026-09-27 真机踩到的坑：写成了
          //     ...sections.map(标题)
          //     ...sections.map(网格)
          // 手机上的样子是「考勤管理」「超市应用」两个标题**叠在顶上**，
          // 底下跟着一整片网格 —— 于是「组织通讯录 / 考勤记录」明明是考勤组
          // 的，却被压在「超市应用」标题下面，看着就像两组重叠、也没分开。
          // 分组数据、组序（都是服务端下发的 sort）其实一直是对的，
          // **错的只有渲染顺序**。
          for (final s in sections) ...[
            SliverToBoxAdapter(
              child: _sectionTitleBar(
                s['label']?.toString() ?? '',
                count: (s['_items'] as List).length,
              ),
            ),
            SliverToBoxAdapter(child: _grid(s['_items'] as List)),
          ],
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 28)),
      ],
    );
  }

  /// 顶部公告：横滑的一条卡片。没配公告时这段整体不出现。
  ///
  /// 卡片宽度撑满可用宽度（左右各 14 内边距），避免窄屏上右侧空出一块、左右不对称。
  /// 点卡片弹「公告详情」（标题 + 正文 + 背景图），正文在管理台「公告台」填写。
  Widget _noticeSliver() {
    final sem = AppSemantic.of(context);
    // 横向 ListView 的左右内边距各 14，所以单卡宽度 = 屏宽 - 28，正好铺满、右侧不空。
    final cardW = MediaQuery.of(context).size.width - 28;
    return SliverToBoxAdapter(
      child: SizedBox(
        height: 78,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
          itemCount: _notices.length,
          separatorBuilder: (_, __) => const SizedBox(width: 10),
          itemBuilder: (ctx, i) {
            final n = _notices[i];
            final text = n['text']?.toString() ?? '';
            final content = n['content']?.toString() ?? '';
            final bgRaw = n['bgUrl']?.toString() ?? '';
            final hasBg = bgRaw.isNotEmpty;
            // 背景图是相对路径（/files/...），拼上当前服务器地址才是可加载的绝对地址
            final bgAbs = hasBg ? '${Config.baseUrl}$bgRaw' : '';
            final card = Container(
              width: cardW,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                // 公告底色用品牌色的浅调，不用"红底白字"——那是在报警，不是在通知。
                // 有背景图时改用图片 + 暗化滤镜，文字转白保证可读。
                color: hasBg ? null : sem.cardBg,
                image: hasBg
                    ? DecorationImage(
                        image: NetworkImage(bgAbs),
                        fit: BoxFit.cover,
                        colorFilter: const ColorFilter.mode(
                          Color(0x66000000),
                          BlendMode.darken,
                        ),
                      )
                    : null,
                borderRadius: BorderRadius.circular(AppRadii.md),
                border: Border.all(color: sem.cardBorder),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Icon(Icons.campaign_outlined,
                      size: 18, color: hasBg ? Colors.white : AppColors.brand),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      text,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13.5,
                        height: 1.5,
                        color: hasBg ? Colors.white : AppColors.text,
                      ),
                    ),
                  ),
                  // 有正文才给个">"暗示可点开看详情
                  if (content.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(left: 8),
                      child: Icon(Icons.chevron_right,
                          size: 16, color: hasBg ? Colors.white70 : sem.muted),
                    ),
                ],
              ),
            );
            // 整张卡可点：弹详情。即使没有正文也允许点（详情里只有标题）。
            return Material(
              color: Colors.transparent,
              child: InkWell(
                borderRadius: BorderRadius.circular(AppRadii.md),
                onTap: () => _openNoticeDetail(text, content, hasBg ? bgAbs : ''),
                child: card,
              ),
            );
          },
        ),
      ),
    );
  }

  /// 公告详情弹窗：标题 + 正文（管理台填的「正文」）+ 背景图。
  /// 背景图存在时当头图，没有则用品牌色小标 + 标题。
  void _openNoticeDetail(String text, String content, String bgAbs) {
    final sem = AppSemantic.of(context);
    final hasBg = bgAbs.isNotEmpty;
    showDialog(
      context: context,
      builder: (dctx) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadii.lg)),
        clipBehavior: Clip.antiAlias,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 460,
            maxHeight: MediaQuery.of(context).size.height * 0.82,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (hasBg)
                Stack(
                  children: [
                    Image.network(bgAbs, height: 150, width: double.infinity, fit: BoxFit.cover),
                    Container(height: 150, width: double.infinity, color: Colors.black.withOpacity(0.42)),
                    Positioned(
                      left: 16, right: 16, bottom: 14,
                      child: Text(text,
                          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: Colors.white)),
                    ),
                  ],
                )
              else
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 18, 18, 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.campaign_outlined, color: AppColors.brand, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(text,
                            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600, color: AppColors.text)),
                      ),
                    ],
                  ),
                ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(18, 14, 18, 6),
                  child: Text(
                    content.isNotEmpty ? content : '（该公告暂无正文）',
                    style: TextStyle(
                      fontSize: 14.5,
                      height: 1.75,
                      color: content.isNotEmpty ? AppColors.text : sem.muted,
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(dctx).pop(),
                      child: const Text('知道了'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 分组标题栏：组名居中 + 右侧该组的应用数。
  ///
  /// 带上数量是为了让"这一组的边界在哪"一眼可辨 —— 只有一行小标题贴着
  /// 下一组的网格时，管理员很难判断上排那两个格子到底归谁。
  /// 标题上方留 20 的间距，避免两组贴在一起看不出分段。
  ///
  /// 🔴 标题居中（龙哥 2026-10-15 要求，对齐钉钉工作台）：钉钉的分组标题
  ///    是居中的，左对齐看着"像文档目录而不像工作台"。
  Widget _sectionTitleBar(String t, {int count = 0}) {
    final sem = AppSemantic.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 20, 14, 10),
      child: Stack(
        alignment: Alignment.center,
        children: [
          Text(t,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: sem.muted,
                  letterSpacing: 0.5)),
          if (count > 0)
            Positioned(
              right: 0,
              child: Text('$count',
                  style: TextStyle(
                      fontSize: 12, color: sem.muted.withOpacity(0.65))),
            ),
        ],
      ),
    );
  }

  /// 统一的彩色图标网格。
  ///
  /// 🔴 列数要按**扣掉左右边距之后**的宽度算。不扣的话，宽屏刚好卡在阈值上
  /// 会出现"格子被挤出屏幕边缘"的半列。
  ///
  /// 🔴 钉钉工作台样式（龙哥 2026-10-15 要求）：整组应用包在一个圆角白卡片里，
  ///    格子本身不再带边框/底色 —— "分组即卡片"，一组的边界一眼可辨，
  ///    也不会出现四列小方框挤在一起的那种"表格感"。
  Widget _grid(List list) {
    final sem = AppSemantic.of(context);
    return LayoutBuilder(builder: (ctx, c) {
      // 卡片自带左右 14 的外边距（不贴屏幕边）；网格内部左右 8 是格子与卡边的呼吸
      final inner = (c.maxWidth - 28).clamp(0.0, double.infinity);
      return Container(
        margin: const EdgeInsets.symmetric(horizontal: 14),
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: BoxDecoration(
          color: sem.cardBg,
          borderRadius: BorderRadius.circular(AppRadii.lg),
          border: Border.all(color: sem.cardBorder),
        ),
        child: GridView.count(
          key: ValueKey('grid_$_kw'),
          crossAxisCount: workbenchColumns(inner),
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
          mainAxisSpacing: 12,
          crossAxisSpacing: 8,
          childAspectRatio: 1 / 1.12,
          children: list.map((a) => _card(a as Map<String, dynamic>)).toList(),
        ),
      );
    });
  }

  /// 一个应用格子：彩色圆底图标 + 名称 + 角标。
  /// desc 不在这里显示 —— 一排四列带两行小字的格子，图标就被挤扁了，
  /// 而 desc 的作用是"起疑心"，不是"解释"（点击就进去了）。
  ///
  /// 🔴 格子本身透明无边框（2026-10-15 钉钉样式）：分组的外框由 _grid 的
  ///    圆角白卡片统一承担，格子里再画边框会出现"卡中卡"的双层框。
  Widget _card(Map<String, dynamic> app) {
    final badge = (app['badge'] ?? '').toString();
    final color = workbenchAppColor(app);
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadii.md),
      onTap: () => _open(app),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: // 🔴 这里必须写 StackFit.expand + Alignment.center。
            //
            // Stack 默认 fit=loose、alignment=topStart：它的尺寸是"最大非定位
            // 子件"的尺寸，而子件 Column 的宽度又只跟**文字本身的宽度**走。
            // 于是格子一宽（宽屏 8 列）、标题一短（"盘点"两个字），
            // Stack 就比格子窄，被 Container 按默认摆到左上 ——
            // 图标就"偏左、看着不居中"；带上角标时更明显（部分定位的子件
            // 会参与撑尺寸，Stack 又被撑成另一个大小，图标位置跟着跳）。
            // 改成 expand + center 之后：Stack 严格铺满格子，Column 在里头
            // 上下左右都居中，跟标题长短、有没有角标都无关。
            Stack(
          fit: StackFit.expand,
          alignment: Alignment.center,
          children: [
            // 🔴 必须包 FittedBox(scaleDown)：expand 之后 Stack 被钉成格子大小，
            // 而图标46+间距10+文字≈19 ≈ 75px，宽屏 8 列时格子只有 ~69px 高 ——
            // 裸 Column 直接溢出 6px（CI workbench_test 9 连红抓的就是它，
            // 真机宽屏上会画出黄黑条纹）。scaleDown 只在放不下时等比缩，
            // 空间够时零变化，居中语义不变。
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // 彩色圆底：圆角比图标本身大一圈是刻意的，企微/飞书都是圆的
                  Container(
                    width: 46,
                    height: 46,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(23),
                    ),
                    child: Icon(
                      moduleIcon(app['icon']?.toString() ?? ''),
                      color: Colors.white,
                      size: 24,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    app['title']?.toString() ?? '应用',
                    maxLines: 1,
                    textAlign: TextAlign.center,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
            ),
            if (badge.isNotEmpty)
              Positioned(
                right: 6,
                top: 6,
                child: Container(
                  constraints: const BoxConstraints(minWidth: 18),
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: AppColors.danger,
                    borderRadius: BorderRadius.circular(AppRadii.pill),
                  ),
                  child: Text(
                    badge,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 10, color: Colors.white, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
          ],
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
