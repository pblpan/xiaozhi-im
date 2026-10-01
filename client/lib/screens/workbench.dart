import 'package:flutter/material.dart';

import '../api.dart';
import '../core/app_version.dart';
import '../core/apps.dart';
import '../core/module_schema.dart';
import '../core/theme.dart';
import '../core/config.dart';
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
  List<Map<String, dynamic>> _apps = const [];
  List<Map<String, dynamic>> _groups = const [];
  List<Map<String, dynamic>> _notices = const [];
  final TextEditingController _q = TextEditingController();
  String _kw = '';

  @override
  void initState() {
    super.initState();
    _q.addListener(() {
      final v = _q.text.trim().toLowerCase();
      if (v != _kw) setState(() => _kw = v);
    });
    _load();
  }

  @override
  void dispose() {
    _q.dispose();
    super.dispose();
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
        // 分组清单跟着下发，客户端不写死组名（管理员可以在管理台改）
        _groups = ((r['groups'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        // 公告：没配就是空列表，客户端不编一条默认的出来
        _notices = ((r['notices'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
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
  Widget _noticeSliver() {
    final sem = AppSemantic.of(context);
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
            final bgRaw = n['bgUrl']?.toString() ?? '';
            final hasBg = bgRaw.isNotEmpty;
            // 背景图是相对路径（/files/...），拼上当前服务器地址才是可加载的绝对地址
            final bgAbs = hasBg ? '${Config.baseUrl}$bgRaw' : '';
            return Container(
              width: 300,
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
                crossAxisAlignment: CrossAxisAlignment.start,
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
                        color: hasBg ? Colors.white : null,
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  /// 分组标题栏：组名 + 右侧该组的应用数。
  ///
  /// 带上数量是为了让"这一组的边界在哪"一眼可辨 —— 只有一行小标题贴着
  /// 下一组的网格时，管理员很难判断上排那两个格子到底归谁。
  /// 标题上方留 20 的间距，避免两组贴在一起看不出分段。
  Widget _sectionTitleBar(String t, {int count = 0}) {
    final sem = AppSemantic.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 20, 14, 10),
      child: Row(
        children: [
          Text(t,
              style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: sem.muted,
                  letterSpacing: 0.5)),
          if (count > 0) ...[
            const SizedBox(width: 8),
            Text('$count',
                style: TextStyle(fontSize: 12, color: sem.muted.withOpacity(0.65))),
          ],
        ],
      ),
    );
  }

  /// 统一的彩色图标网格。
  /// 统一的彩色图标网格。
  ///
  /// 🔴 列数要按**扣掉左右边距之后**的宽度算。不扣的话，宽屏刚好卡在阈值上
  /// 会出现"格子被挤出屏幕边缘"的半列。
  Widget _grid(List list) {
    return LayoutBuilder(builder: (ctx, c) {
      // 网格自带左右 14 的边距（格子不再贴着屏幕边，那也是"排版乱"的一部分）
      final inner = (c.maxWidth - 28).clamp(0.0, double.infinity);
      return GridView.count(
        key: ValueKey('grid_$_kw'),
        crossAxisCount: workbenchColumns(inner),
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        mainAxisSpacing: 14,
        crossAxisSpacing: 14,
        childAspectRatio: 1 / 1.15,
        children: list.map((a) => _card(a as Map<String, dynamic>)).toList(),
      );
    });
  }

  /// 一个应用格子：彩色圆底图标 + 名称 + 角标。
  /// desc 不在这里显示 —— 一排四列带两行小字的格子，图标就被挤扁了，
  /// 而 desc 的作用是"起疑心"，不是"解释"（点击就进去了）。
  Widget _card(Map<String, dynamic> app) {
    final sem = AppSemantic.of(context);
    final badge = (app['badge'] ?? '').toString();
    final color = workbenchAppColor(app);
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadii.md),
      onTap: () => _open(app),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        decoration: BoxDecoration(
          color: sem.cardBg,
          borderRadius: BorderRadius.circular(AppRadii.md),
          border: Border.all(color: sem.cardBorder),
        ),
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
