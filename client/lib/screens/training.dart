import 'package:flutter/material.dart';

import '../api.dart';
import '../core/theme.dart';
import 'training_course.dart';

/// 培训中心：课程列表（公共课程 / 我的课程）。
///
/// ── 为什么要分这两个 tab ────────────────────────────────────
/// 素材盘里有 200+ 个文件，铺开是一张很长的表。学员真正要的是
/// "我要学的那几门"，不是"全部"。不分的话，每次进来都要从头找一遍，
/// 用两次就没人用了。
///
/// ── 「有数据才渲染」的老毛病 ────────────────────────────────
/// 进度条、章节数这些**没数据也要画出来**（画成 0% 或"—"），
/// 否则学员看到的是一片空白，会以为"这里没有内容"。
class TrainingPage extends StatefulWidget {
  const TrainingPage({super.key});

  @override
  State<TrainingPage> createState() => _TrainingPageState();
}

class _TrainingPageState extends State<TrainingPage>
    with SingleTickerProviderStateMixin {
  final ImApi _api = ImApi();
  late final TabController _tabs;

  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _public = const [];
  List<Map<String, dynamic>> _mine = const [];
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this)
      ..addListener(() {
        if (_tabs.index == _tab) return;
        setState(() => _tab = _tabs.index);
      });
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final pub = await _api.trainingCourses(scope: 'public');
      final mine = await _api.trainingCourses(scope: 'mine');
      if (!mounted) return;
      setState(() {
        _public = _rowsOf(pub);
        _mine = _rowsOf(mine);
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  static List<Map<String, dynamic>> _rowsOf(Map<String, dynamic> body) =>
      (body['items'] as List? ?? const [])
          .whereType<Map<String, dynamic>>()
          .toList();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('培训中心'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [
            Tab(text: '公共课程'),
            Tab(text: '我的课程'),
          ],
        ),
        actions: [
          IconButton(
            key: const Key('training-refresh'),
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: _load,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : (_error != null
              ? _ErrorView(msg: _error!, onRetry: _load)
              : TabBarView(
                  controller: _tabs,
                  children: [
                    _CourseList(
                      rows: _public,
                      empty: '还没有发布的课程',
                      onRefresh: _load,
                    ),
                    _CourseList(
                      rows: _mine,
                      empty: '还没加入课程 — 去「公共课程」里挑一门',
                      onRefresh: _load,
                    ),
                  ],
                )),
      // 🔴 空态也要给一句"去哪加"，不然学员看到空白只会以为坏了
      bottomNavigationBar: _error == null && !_loading
          ? Container(
              color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Text(
                '课程由管理员在管理后台发布；加入后会出现在「我的课程」里。',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
            )
          : null,
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String msg;
  final VoidCallback onRetry;
  const _ErrorView({required this.msg, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 40),
            const SizedBox(height: 10),
            Text(msg, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            FilledButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}

class _CourseList extends StatelessWidget {
  final List<Map<String, dynamic>> rows;
  final String empty;
  final VoidCallback onRefresh;
  const _CourseList(
      {required this.rows, required this.empty, required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(empty, textAlign: TextAlign.center),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () async => onRefresh(),
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: rows.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (_, i) => _CourseTile(course: rows[i], onChanged: onRefresh),
      ),
    );
  }
}

class _CourseTile extends StatelessWidget {
  final Map<String, dynamic> course;
  final VoidCallback onChanged;
  const _CourseTile({required this.course, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = '${course['title'] ?? ''}';
    final category = '${course['category'] ?? ''}';
    final required = course['required'] == true;
    final joined = course['joined'] == true;
    final pct = (course['progressPct'] is num) ? course['progressPct'] as num : 0;
    final lessons = course['lessonCount'] ?? 0;

    return ListTile(
      key: Key('training-course-${course['id']}'),
      leading: const Icon(Icons.school_outlined),
      title: Row(children: [
        Expanded(child: Text(title, overflow: TextOverflow.ellipsis)),
        if (required)
          Container(
            margin: const EdgeInsets.only(left: 6),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: AppColors.brand.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text('必修',
                style:
                    theme.textTheme.labelSmall?.copyWith(color: AppColors.brand)),
          ),
      ]),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (category.isNotEmpty) Text(category),
          const SizedBox(height: 4),
          // 🔴 0% 也要画出来：不画的话学员会以为"进度没记上"
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: (pct / 100).clamp(0.0, 1.0),
              minHeight: 5,
              backgroundColor: theme.colorScheme.surfaceContainerHighest,
            ),
          ),
          const SizedBox(height: 2),
          Text('$lessons 课时 · 已学 ${pct.toInt()}%'),
        ],
      ),
      trailing: joined
          ? const Icon(Icons.check_circle_outline)
          : const Icon(Icons.add_circle_outline),
      onTap: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
              builder: (_) => TrainingCoursePage(courseId: course['id'] as int)),
        );
        onChanged();
      },
    );
  }
}
