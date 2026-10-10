import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:xiaozhi_im_client/api.dart';
import 'package:xiaozhi_im_client/core/config.dart';
import 'package:xiaozhi_im_client/core/theme.dart';
import 'package:xiaozhi_im_client/screens/training_course.dart';
import 'package:xiaozhi_im_client/widgets/cached_image.dart';

/// 群功能面板：群文件 / 群相册 / 群视频 / 群课堂。
///
/// 前三样服务端是**从消息流聚合**的（不是单独的"群文件表"），所以这里看到
/// 的东西永远和聊天记录一致 —— 消息撤回，它就没了。
/// 群课堂关联的是培训中心里已有的课程，点进去就是那个课程页，不另做一套。
class GroupPanelScreen extends StatefulWidget {
  final int groupId;
  final String groupName;

  /// 群主/管理员才显示「挂课程」（由服务端下发，客户端不自己猜）
  final bool canManage;

  const GroupPanelScreen({
    super.key,
    required this.groupId,
    required this.groupName,
    this.canManage = false,
  });

  @override
  State<GroupPanelScreen> createState() => _GroupPanelScreenState();
}

class _GroupPanelScreenState extends State<GroupPanelScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;
  final Map<int, List<Map<String, dynamic>>> _cache = {};
  final Map<int, bool> _loading = {};
  Map<String, dynamic> _courses = const {};
  bool _coursesLoading = true;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 4, vsync: this);
    _load(0);
    _loadCourses();
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  Future<void> _load(int i) async {
    if (_cache.containsKey(i)) return;
    setState(() => _loading[i] = true);
    try {
      final List<dynamic> items;
      switch (i) {
        case 0:
          items = await ImApi().groupFiles(widget.groupId);
          break;
        case 1:
          items = await ImApi().groupAlbums(widget.groupId);
          break;
        case 2:
          items = await ImApi().groupVideos(widget.groupId);
          break;
        default:
          items = const [];
      }
      if (!mounted) return;
      setState(() {
        _cache[i] = items.cast<Map<String, dynamic>>();
        _loading[i] = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading[i] = false);
      _toast('加载失败：${_msg(e)}');
    }
  }

  Future<void> _loadCourses() async {
    try {
      final c = await ImApi().groupCourses(widget.groupId);
      if (!mounted) return;
      setState(() {
        _courses = c;
        _coursesLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _coursesLoading = false);
    }
  }

  String _msg(Object e) => e.toString().replaceFirst('Exception: ', '');

  void _toast(String s) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(s), duration: const Duration(seconds: 2)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.groupName),
        bottom: TabBar(
          controller: _tab,
          onTap: (i) {
            if (i < 3) _load(i);
          },
          tabs: const [
            Tab(text: '群文件'),
            Tab(text: '群相册'),
            Tab(text: '群视频'),
            Tab(text: '群课堂'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: [
          _mediaList(0, empty: '群里还没发过文件'),
          _albumGrid(),
          _mediaList(2, empty: '群里还没发过视频'),
          _courseList(),
        ],
      ),
    );
  }

  // --------------------------------------------------------------- 文件/视频

  Widget _mediaList(int idx, {required String empty}) {
    if (_loading[idx] == true) {
      return const Center(child: CircularProgressIndicator());
    }
    final items = _cache[idx] ?? const [];
    if (items.isEmpty) return _empty(empty);
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: items.length,
      separatorBuilder: (_, __) => const Divider(height: 1, indent: 14),
      itemBuilder: (ctx, i) => _mediaTile(items[i]),
    );
  }

  Widget _mediaTile(Map<String, dynamic> m) {
    final name = (m['name'] ?? '未命名文件') as String;
    final size = m['size'] as int?;
    final who = (m['sender'] as Map?)?['name'] ?? '';
    final at = (m['createdAt'] ?? 0) as int;
    return ListTile(
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: AppColors.surfaceHi,
          borderRadius: BorderRadius.circular(AppRadii.sm),
        ),
        child: const Icon(Icons.insert_drive_file_rounded,
            color: AppColors.textSub, size: 20),
      ),
      title: Text(name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
      subtitle: Text(
        [if (who.isNotEmpty) who, if (size != null) _bytes(size), _when(at)]
            .where((s) => s.isNotEmpty)
            .join(' · '),
        style: const TextStyle(fontSize: 11.5, color: AppColors.textWeak),
      ),
      trailing: const Icon(Icons.open_in_new_rounded, size: 18, color: AppColors.textWeak),
      onTap: () => _open(m['url'] as String?),
    );
  }

  static String _bytes(int n) {
    if (n < 1024) return '$n B';
    if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(0)} KB';
    return '${(n / 1024 / 1024).toStringAsFixed(1)} MB';
  }

  String _when(int ms) {
    if (ms <= 0) return '';
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.month}/${d.day} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _open(String? url) async {
    if (url == null || url.isEmpty) {
      _toast('这个文件没有可访问的地址');
      return;
    }
    final full = url.startsWith('http') ? url : '${Config.baseUrl}$url';
    final uri = Uri.tryParse(full);
    if (uri == null || !await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      if (mounted) _toast('打不开：$full');
    }
  }

  // --------------------------------------------------------------- 群相册

  Widget _albumGrid() {
    if (_loading[1] == true) {
      return const Center(child: CircularProgressIndicator());
    }
    final items = _cache[1] ?? const [];
    if (items.isEmpty) return _empty('群里还没发过图片');
    return GridView.builder(
      padding: const EdgeInsets.all(10),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 6,
        mainAxisSpacing: 6,
      ),
      itemCount: items.length,
      itemBuilder: (ctx, i) {
        final url = items[i]['url'] as String? ?? '';
        final full = url.startsWith('http') ? url : '${Config.baseUrl}$url';
        return GestureDetector(
          onTap: () => _preview(full),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AppRadii.sm),
            child: XzCachedImage(url: full, fit: BoxFit.cover),
          ),
        );
      },
    );
  }

  void _preview(String full) {
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(12),
        child: Stack(
          children: [
            Center(child: InteractiveViewer(child: XzCachedImage(url: full))),
            Positioned(
              right: 4,
              top: 4,
              child: IconButton(
                icon: const Icon(Icons.close_rounded, color: Colors.white),
                onPressed: () => Navigator.pop(ctx),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // --------------------------------------------------------------- 群课堂

  Widget _courseList() {
    if (_coursesLoading) return const Center(child: CircularProgressIndicator());
    final items = (_courses['items'] as List?) ?? const [];
    final canManage = _courses['canManage'] == true || widget.canManage;

    if (items.isEmpty) {
      return _empty(
        canManage ? '这个群还没挂课程，点下面「挂课程」添加' : '这个群还没有群课堂',
        action: canManage
            ? FilledButton.icon(
                onPressed: _pickCourse,
                icon: const Icon(Icons.add_rounded),
                label: const Text('挂课程'),
              )
            : null,
      );
    }

    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        for (final c in items.cast<Map<String, dynamic>>()) _courseCard(c),
        if (canManage) ...[
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _pickCourse,
            icon: const Icon(Icons.add_rounded),
            label: const Text('再挂一门课'),
          ),
        ],
      ],
    );
  }

  Widget _courseCard(Map<String, dynamic> c) {
    final id = (c['id'] ?? 0) as int;
    final pct = (c['progressPct'] ?? 0) as int;
    final lessons = (c['lessonCount'] ?? 0) as int;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadii.md),
        onTap: () => Navigator.push(context,
            MaterialPageRoute(builder: (_) => TrainingCoursePage(courseId: id))),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text((c['title'] ?? '') as String,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600)),
                  ),
                  if (_courses['canManage'] == true)
                    IconButton(
                      tooltip: '从群里摘掉',
                      icon: const Icon(Icons.remove_circle_outline_rounded,
                          size: 18, color: AppColors.textWeak),
                      onPressed: () => _unlink(id),
                    ),
                ],
              ),
              if (((c['intro'] ?? '') as String).isNotEmpty) ...[
                const SizedBox(height: 4),
                Text((c['intro'] ?? '') as String,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 12.5, color: AppColors.textSub)),
              ],
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: pct / 100,
                  minHeight: 5,
                  backgroundColor: AppColors.surfaceHi,
                  valueColor: const AlwaysStoppedAnimation(AppColors.brand),
                ),
              ),
              const SizedBox(height: 6),
              Text('$lessons 课时 · 已学 $pct%',
                  style: const TextStyle(fontSize: 11.5, color: AppColors.textWeak)),
            ],
          ),
        ),
      ),
    );
  }

  /// 挂课程：从培训中心已发布的课里挑一门
  Future<void> _pickCourse() async {
    List<dynamic> all = const [];
    try {
      final r = await ImApi().trainingCourses(scope: 'public');
      all = (r['items'] as List?) ?? const [];
    } catch (e) {
      if (mounted) _toast('拉取课程失败：${_msg(e)}');
      return;
    }
    if (!mounted) return;
    if (all.isEmpty) {
      _toast('培训中心还没有已发布的课程，先去管理台建一门');
      return;
    }
    final picked = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('挂一门课到群里'),
        children: [
          for (final c in all.cast<Map<String, dynamic>>())
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, (c['id'] ?? 0) as int),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Text('${c['title']}（${c['lessonCount'] ?? 0} 课时）'),
              ),
            ),
        ],
      ),
    );
    if (picked == null || picked == 0) return;
    try {
      await ImApi().linkGroupCourse(widget.groupId, picked);
      if (mounted) _toast('已挂到群里');
      await _loadCourses();
    } catch (e) {
      if (mounted) _toast('挂课程失败：${_msg(e)}');
    }
  }

  Future<void> _unlink(int courseId) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('从群里摘掉这门课？'),
        content: const Text('只是解除群与课程的关联，课程本身还在培训中心，不会删。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('摘掉')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ImApi().unlinkGroupCourse(widget.groupId, courseId);
      await _loadCourses();
      if (mounted) _toast('已摘掉');
    } catch (e) {
      if (mounted) _toast('操作失败：${_msg(e)}');
    }
  }

  // --------------------------------------------------------------- 空态

  Widget _empty(String text, {Widget? action}) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.inbox_rounded, size: 44, color: AppColors.textWeak),
              const SizedBox(height: 12),
              Text(text,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppColors.textWeak, fontSize: 13)),
              if (action != null) ...[const SizedBox(height: 16), action],
            ],
          ),
        ),
      );
}
