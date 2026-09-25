import 'package:flutter/material.dart';

import '../api.dart';
import '../core/file_io.dart';
import '../core/lesson_player.dart';
import 'lesson_player_page.dart';
import 'training_exam.dart';

/// 课程详情：章节 → 课时（点开看课件）/ 章节考试。
///
/// ── 课件怎么播（2026-09-25 改过，别照着老注释改回去）──────────
/// · **手机端（Android/iOS）**：课件视频走**内嵌播放器**（screens/lesson_player_page.dart）。
///   只有内嵌才能数出"真看了多少秒"，完成率才是真的 —— 老口径是
///   "交给系统播放器、打开成功就记完成"，点开就退出也算学完。
/// · **Windows 桌面端**：`video_player` 没有 Windows 实现（见 core/lesson_player.dart），
///   继续走系统播放器。桌面端不是培训的主场（学员用手机看），
///   但**文档类课件在任何平台都走系统播放器** —— 内嵌播放器只管视频。
///
/// ⚠️ 判据不是"打开过"，而是"真看完 90%"（core/lesson_progress.dart）。
///    拖进度条跳过去的不算，暂停/缓冲的不算，倍速的照算。
///
/// ── 考试入口为什么在章节上 ──────────────────────────────────
/// "学完一章考一章"，才有"进度不达标不放行"的落脚点。
/// 考试挂在课程上的话，学员可以只看第一章就去考整门课。
class TrainingCoursePage extends StatefulWidget {
  final int courseId;
  const TrainingCoursePage({super.key, required this.courseId});

  @override
  State<TrainingCoursePage> createState() => _TrainingCoursePageState();
}

class _TrainingCoursePageState extends State<TrainingCoursePage> {
  final ImApi _api = ImApi();
  bool _loading = true;
  String? _error;
  Map<String, dynamic> _course = const {};
  List<Map<String, dynamic>> _chapters = const [];
  bool _joined = false;
  int _busyLesson = 0;

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
      final body = await _api.trainingCourse(widget.courseId);
      if (!mounted) return;
      setState(() {
        _course = (body['course'] as Map?)?.cast<String, dynamic>() ?? const {};
        _chapters = (body['chapters'] as List? ?? const [])
            .whereType<Map<String, dynamic>>()
            .toList();
        _joined = body['joined'] == true;
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

  Future<void> _toggleJoin() async {
    try {
      if (_joined) {
        await _api.quitCourse(widget.courseId);
      } else {
        await _api.joinCourse(widget.courseId);
      }
      if (!mounted) return;
      setState(() => _joined = !_joined);
      _tip(_joined ? '已加入「我的课程」' : '已移出「我的课程」');
    } catch (e) {
      _tip('$e');
    }
  }

  void _tip(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 打开课件：下载到本地（已下过就直接复用）→ 播。
  ///
  /// 两条路，判据完全不同：
  /// · 内嵌播放器（手机端视频）：秒数由播放器自己数，**完成由播放器判定**；
  ///   这里只负责刷新列表，不再"打开即标记完成"。
  /// · 系统播放器（桌面端 / 文档）：拿不到秒数，只能沿用"打开成功就记完成"。
  ///
  /// 🔴 「标记已看」放在打开**成功**之后：下载失败/没装播放器时不标记，
  ///    否则学员会拿到一个"看了但其实没打开"的完成率。
  Future<void> _openLesson(Map<String, dynamic> lesson) async {
    final id = lesson['id'] as int? ?? 0;
    final fileId = lesson['fileId'] as int? ?? 0;
    if (id == 0 || fileId == 0) {
      _tip('这个课时还没有课件，请管理员先上传');
      return;
    }
    setState(() => _busyLesson = id);
    try {
      final title = '${lesson['title'] ?? '课件'}';
      final f = await FileIo.ensure(
        url: _api.lessonMediaUrl(id),
        fileId: fileId,
        name: title,
        headers: _api.authHeaders,
      );

      // 🔴 只有"视频 + 这台设备支持内嵌"才走内嵌。文档类在任何平台都走系统打开。
      final isVideo = '${lesson['kind'] ?? ''}' != 'doc';
      if (isVideo && LessonPlayer.supported) {
        if (!mounted) return;
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => LessonPlayerPage(
              lessonId: id,
              title: title,
              filePath: f.path,
              serverDurationSec: lesson['durationSec'] as int? ?? 0,
              startSec: lesson['positionSec'] as int? ?? 0,
            ),
          ),
        );
        // 播放器退出时已上报过一次（dispose 里兜底），这里只把列表刷成最新。
        if (!mounted) return;
        await _load();
        return;
      }

      final err = await FileIo.open(f);
      if (err.isNotEmpty) {
        _tip(err);
        return;
      }
      await _api.reportLessonProgress(id, done: true);
      if (!mounted) return;
      setState(() {
        for (final ch in _chapters) {
          final ls = (ch['lessons'] as List? ?? const []);
          for (var i = 0; i < ls.length; i++) {
            if (ls[i]['id'] == id) {
              ls[i] = {...ls[i] as Map<String, dynamic>, 'done': true};
            }
          }
        }
      });
    } catch (e) {
      _tip('打开课件失败：$e');
    } finally {
      if (mounted) setState(() => _busyLesson = 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = '${_course['title'] ?? '课程'}';
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          TextButton.icon(
            key: const Key('training-join'),
            icon: Icon(_joined ? Icons.check_circle : Icons.add_circle_outline),
            label: Text(_joined ? '已加入' : '加入课程'),
            onPressed: _loading ? null : _toggleJoin,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : (_error != null
              ? Center(child: Text(_error!))
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView(
                    padding: const EdgeInsets.all(12),
                    children: [
                      if ('${_course['intro'] ?? ''}'.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Text('${_course['intro']}',
                              style: theme.textTheme.bodyMedium),
                        ),
                      for (final ch in _chapters)
                        _ChapterCard(
                          chapter: ch,
                          busyLesson: _busyLesson,
                          onOpenLesson: _openLesson,
                          onExam: _startExam,
                        ),
                      if (_chapters.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(24),
                          child: Center(child: Text('这门课还没有章节')),
                        ),
                    ],
                  ),
                )),
    );
  }

  Future<void> _startExam(Map<String, dynamic> exam) async {
    final id = exam['id'] as int? ?? 0;
    if (id == 0) return;
    try {
      final body = await _api.startExam(id);
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
            builder: (_) => TrainingExamPage(
                  sheetId: body['sheetId'] as int,
                  title: '${exam['title'] ?? '考试'}',
                  started: body,
                )),
      );
      _load();
    } on ApiException catch (e) {
      // 🔴 三种失败要分开说，一律弹"加载失败"的话，学员不知道该去干嘛
      if (e.code == 'progress_not_reached') {
        final pct = (e.data?['progressPct'] ?? 0);
        final min = (e.data?['minProgress'] ?? 100);
        _tip('本章进度 $pct%，学到 $min% 才能考试');
      } else if (e.code == 'no_attempt_left') {
        _tip('考试机会已用完');
      } else if (e.code == 'already_started') {
        _tip('你已经进入过这场考试了');
      } else {
        _tip(e.message);
      }
    } catch (e) {
      _tip('$e');
    }
  }
}

/// 课时副标题：类型 + 时长 + 学到哪。
///
/// 这里**故意不写"已完成"以外的话术**：真正判完成的是 `done`，
/// 而 `positionSec`（上次看到哪）只是续播用的，别让人误以为"看到 90% 就算过"。
String _lessonSubtitle(Map<String, dynamic> l) {
  final parts = <String>[l['kind'] == 'doc' ? '文档' : '视频'];
  final dur = l['durationSec'] as int? ?? 0;
  if (dur > 0) parts.add('${(dur / 60).round()} 分');
  final pos = l['positionSec'] as int? ?? 0;
  if (pos > 0) parts.add('上次看到 ${_mmss(pos)}');
  // 服务端记的"真看了多少秒"（手机端内嵌播放才会涨；
  // 桌面端/文档走系统播放器，拿不到，就不会显示这一项）。
  final watched = l['watchedSec'] as int? ?? 0;
  if (watched > 0) parts.add('真看了 ${_mmss(watched)}');
  return parts.join(' · ');
}

String _mmss(int seconds) {
  final s = seconds < 0 ? 0 : seconds;
  return '${(s ~/ 60).toString().padLeft(2, '0')}'
      ':${(s % 60).toString().padLeft(2, '0')}';
}

class _ChapterCard extends StatelessWidget {
  final Map<String, dynamic> chapter;
  final int busyLesson;
  final void Function(Map<String, dynamic>) onOpenLesson;
  final void Function(Map<String, dynamic>) onExam;
  const _ChapterCard(
      {required this.chapter,
      required this.busyLesson,
      required this.onOpenLesson,
      required this.onExam});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lessons = (chapter['lessons'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final exams = (chapter['exams'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final pct = (chapter['progressPct'] is num)
        ? (chapter['progressPct'] as num).toInt()
        : 0;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                  child: Text('${chapter['title'] ?? ''}',
                      style: theme.textTheme.titleMedium)),
              Text('$pct%',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ]),
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: (pct / 100).clamp(0.0, 1.0),
                minHeight: 5,
                backgroundColor: theme.colorScheme.surfaceContainerHighest,
              ),
            ),
            const SizedBox(height: 8),
            if (lessons.isEmpty)
              const Text('（本章还没有课时）')
            else
              for (final l in lessons)
                ListTile(
                  key: Key('training-lesson-${l['id']}'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(l['done'] == true
                      ? Icons.check_circle
                      : Icons.play_circle_outline),
                  title: Text('${l['title'] ?? ''}'),
                  subtitle: Text(_lessonSubtitle(l)),
                  trailing: busyLesson == (l['id'] as int? ?? 0)
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : null,
                  onTap: () => onOpenLesson(l),
                ),
            for (final e in exams) ...[
              const Divider(),
              _ExamRow(exam: e, onTap: () => onExam(e)),
            ],
          ],
        ),
      ),
    );
  }
}

class _ExamRow extends StatelessWidget {
  final Map<String, dynamic> exam;
  final VoidCallback onTap;
  const _ExamRow({required this.exam, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final used = exam['usedAttempts'] ?? 0;
    final limit = exam['attemptLimit'] ?? 1;
    final best = exam['bestScore'] ?? 0;
    final pct = (exam['progressPct'] is num)
        ? (exam['progressPct'] as num).toInt()
        : 0;
    final min = exam['minProgress'] ?? 100;
    final locked = pct < min;
    final usedUp = used >= limit;

    return ListTile(
      key: Key('training-exam-${exam['id']}'),
      dense: true,
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.quiz_outlined),
      title: Text('${exam['title'] ?? '章节考试'}'),
      subtitle: Text(locked
          ? '学到 $min% 才能考（现在 $pct%）'
          : usedUp
              ? '机会已用完 · 最好成绩 $best 分'
              : '及格 ${exam['passScore']} 分 · 还剩 ${limit - used} 次机会'),
      trailing: locked || usedUp
          ? const Icon(Icons.lock_outline)
          : FilledButton(
              onPressed: onTap,
              child: const Text('开始考试'),
            ),
      // 🔴 锁着的时候点了也要说清楚为什么（静默无反应等于功能坏了）
      onTap: locked || usedUp
          ? () => ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(locked
                  ? '本章进度 $pct%，学到 $min% 才能参加考试'
                  : '考试机会已用完')))
          : onTap,
      textColor: theme.colorScheme.onSurface,
    );
  }
}
