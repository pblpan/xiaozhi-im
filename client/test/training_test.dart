import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/api.dart';
import 'package:xiaozhi_im_client/core/config.dart';
import 'package:xiaozhi_im_client/core/file_io.dart';
import 'package:xiaozhi_im_client/screens/training.dart';
import 'package:xiaozhi_im_client/screens/training_course.dart';

import 'support/api_stub.dart';

/// 培训中心列表页 / 课程详情页的测试。
///
/// ── 钉住的是哪几件事 ────────────────────────────────────────────
/// ① **课程按服务端数据渲染**（不是写死的样例）—— 换个课名就不该出现旧的。
/// ② 🔴 **进度 0% 也要画出来**。以前踩过"有数据才渲染"的坑：
///    没进度时控件不画，用户看到空白，以为"进度没记上"。
///    所以这里断言的是 0% 的课**也有进度条**。
/// ③ 加入课程**真的发请求**，且发的是 POST /join（不是本地改个勾就算成功）。
/// ④ 🔴 **考试被门禁挡住时，必须说清楚为什么**。
///    progress_not_reached 要显示"学到 X% 才能考"，
///    一律弹"加载失败"的话学员不知道该去干嘛 —— 这条是这一页最容易做错的。
/// ⑤ 章节/课时**为空时也要有话**（"还没有章节"），不能是一片空白。
/// ⑥ 打开课件走的是**带鉴权头的下载**（不带就是 401）—— 断言真发出去且带了头。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ApiStub stub;

  late Directory tmpDir;

  setUp(() async {
    stub = await ApiStub.start();
    Config.currentUrl = stub.baseUrl;
    ImApi().setToken('tok');
    // 课件下载要落盘；widget 测试里没有 path_provider 插件，必须注入一个真目录
    tmpDir = await Directory.systemTemp.createTemp('xz-training-test-');
    FileIo.dirOverride = tmpDir;
  });

  tearDown(() async {
    stub.stop();
    FileIo.dirOverride = null;
    try {
      await tmpDir.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> pumpUntil(WidgetTester tester, bool Function() ok,
      {int tries = 150, required String why}) async {
    for (var i = 0; i < tries; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 15)));
      await tester.pump(const Duration(milliseconds: 20));
      if (ok()) return;
    }
    fail('等待超时：$why');
  }

  /// 收尾：把还在跑的假时钟定时器走完。
  ///
  /// 🔴 两个来源，缺一个都会以"看不懂"的方式失败：
  ///   · SnackBar 自带 4 秒自动消失定时器
  ///   · **HttpClient 的空闲连接会挂一个 15 秒定时器**
  ///     （`_HttpClientConnection.startTimer`）—— 只 pump 5 秒的话它还在，
  ///     报错写的是 "Pending timers"，跟 SnackBar/下载都看不出关系，
  ///     很容易被当成页面写坏了。
  /// 所以这里累计走够 20 秒以上的假时钟，中间用 runAsync 把真 IO 放出去。
  Future<void> drain(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pump(const Duration(seconds: 5));
    }
    await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pump(const Duration(milliseconds: 100));
  }

  Map<String, Object?> courseRow({
    int id = 1,
    String title = '生鲜陈列基础',
    String category = '生鲜陈列',
    bool required = true,
    int progressPct = 0,
    int lessonCount = 3,
    bool joined = false,
  }) =>
      {
        'id': id,
        'title': title,
        'intro': 'intro',
        'category': category,
        'required': required,
        'chapterCount': 2,
        'lessonCount': lessonCount,
        'progressPct': progressPct,
        'joined': joined,
      };

  Future<void> openList(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: TrainingPage()));
    await pumpUntil(tester, () => tester.widgetList(find.byType(ListTile)).isNotEmpty,
        why: '课程列表加载');
  }

  testWidgets('① 课程按服务端数据渲染', (tester) async {
    stub.on('GET', '/api/training/courses', (r) => {
          'items': [courseRow(id: 7, title: '防损入门', category: '防损')],
          'total': 1,
          'page': 1,
          'pageSize': 20,
        });
    await openList(tester);
    expect(find.text('防损入门'), findsOneWidget);
    expect(find.text('生鲜陈列基础'), findsNothing);
  });

  testWidgets('② 🔴 进度 0% 也要画出来（不画 = 用户以为没记录）', (tester) async {
    stub.on('GET', '/api/training/courses', (r) => {
          'items': [courseRow(progressPct: 0, lessonCount: 0)],
          'total': 1,
          'page': 1,
          'pageSize': 20,
        });
    await openList(tester);
    // 进度条本身要在，且"已学 0%"这行字也要在
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.textContaining('已学 0%'), findsOneWidget);
  });

  testWidgets('③ 加入课程真的发 POST /join', (tester) async {
    stub.on('GET', '/api/training/courses', (r) => {
          'items': [courseRow(id: 5)],
          'total': 1,
          'page': 1,
          'pageSize': 20,
        });
    stub.on('POST', '/api/training/courses/5/join', (r) => {'ok': true, 'courseId': 5});
    stub.on('GET', '/api/training/courses/5', (r) => {
          'course': {'id': 5, 'title': '生鲜陈列基础', 'intro': '', 'category': ''},
          'progressPct': 0,
          'joined': false,
          'chapters': [],
        });
    await openList(tester);
    await tester.tap(find.byKey(const Key('training-course-5')));
    await tester.pumpAndSettle();
    await pumpUntil(tester,
        () => stub.calls.any((c) => c.method == 'GET' && c.path == '/api/training/courses/5'),
        why: '课程详情加载');

    await tester.tap(find.byKey(const Key('training-join')));
    await pumpUntil(tester,
        () => stub.calls.any((c) => c.method == 'POST' && c.path == '/api/training/courses/5/join'),
        why: '加入课程请求');
    expect(
        stub.calls
            .where((c) => c.method == 'POST' && c.path == '/api/training/courses/5/join')
            .length,
        1);
    await drain(tester);
  });

  testWidgets('④ 🔴 考试被门禁挡住时说清为什么（不是"加载失败"）', (tester) async {
    stub.on('GET', '/api/training/courses/9', (r) => {
      'course': {'id': 9, 'title': '陈列', 'intro': '', 'category': ''},
      'progressPct': 40,
      'joined': true,
      'chapters': [
        {
          'id': 1,
          'title': '第一章',
          'sort': 0,
          'progressPct': 40,
          'lessons': [
            {
              'id': 11,
              'title': '课时一',
              'kind': 'video',
              'fileId': 101,
              'durationSec': 600,
              'sort': 0,
              'positionSec': 0,
              'done': false,
            }
          ],
          'exams': [
            {
              'id': 21,
              'title': '第一章考试',
              'passScore': 60,
              'attemptLimit': 1,
              'minProgress': 100,
              'progressPct': 40,
              'usedAttempts': 0,
              'bestScore': 0,
            }
          ],
        }
      ],
    });
    // 服务端按门禁拒绝（带 code 与进度）
    stub.on('POST', '/api/training/exams/21/start',
        (r) => const StubResponse(403, {
              'error': '本章进度 40%，未达到 100% 不能参加考试',
              'code': 'progress_not_reached',
              'progressPct': 40,
              'minProgress': 100,
            }));

    await tester.pumpWidget(const MaterialApp(home: TrainingCoursePage(courseId: 9)));
    await pumpUntil(tester, () => find.text('第一章').evaluate().isNotEmpty,
        why: '课程详情加载');

    // 锁着的考试：入口显示"学到 100% 才能考"，点了要明说
    expect(find.textContaining('学到 100% 才能考'), findsOneWidget);
    await tester.tap(find.byKey(const Key('training-exam-21')));
    await pumpUntil(tester, () => find.byType(SnackBar).evaluate().isNotEmpty,
        why: '门禁提示');
    expect(find.textContaining('学到 100% 才能参加考试'), findsOneWidget);
    await drain(tester);
  });

  testWidgets('⑤ 没有章节时也要有话（不是一片空白）', (tester) async {
    stub.on('GET', '/api/training/courses/3', (r) => {
          'course': {'id': 3, 'title': '空课程', 'intro': '', 'category': ''},
          'progressPct': 0,
          'joined': false,
          'chapters': [],
        });
    await tester.pumpWidget(const MaterialApp(home: TrainingCoursePage(courseId: 3)));
    await pumpUntil(tester, () => find.text('空课程').evaluate().isNotEmpty,
        why: '课程详情加载');
    expect(find.text('这门课还没有章节'), findsOneWidget);
  });

  testWidgets('⑥ 课时按服务端数据渲染（视频/文档要分得清）', (tester) async {
    stub.on('GET', '/api/training/courses/4', (r) => {
      'course': {'id': 4, 'title': '有课件的课', 'intro': '', 'category': ''},
      'progressPct': 0,
      'joined': true,
      'chapters': [
        {
          'id': 2,
          'title': '章节',
          'sort': 0,
          'progressPct': 0,
          'lessons': [
            {
              'id': 12,
              'title': '视频一',
              'kind': 'video',
              'fileId': 202,
              'durationSec': 100,
              'sort': 0,
              'positionSec': 0,
              'done': false,
            },
            {
              'id': 13,
              'title': '课件',
              'kind': 'doc',
              'fileId': 203,
              'durationSec': 0,
              'sort': 1,
              'positionSec': 0,
              'done': true,
            }
          ],
          'exams': [],
        }
      ],
    });
    await tester.pumpWidget(const MaterialApp(home: TrainingCoursePage(courseId: 4)));
    await pumpUntil(
        tester,
        () => find.byKey(const Key('training-lesson-12')).evaluate().isNotEmpty,
        why: '课时渲染');
    expect(find.text('视频一'), findsOneWidget);
    expect(find.text('课件'), findsOneWidget);
    // 已看完的用实心对勾，没看完的用播放圈 —— 让"看到哪了"一眼可见。
    // 🔴 必须**限定在课时行内**查：页面上「已加入课程」按钮也用 check_circle，
    //    全页查会数出 2 个，`findsOneWidget` 反而挂掉 —— 那种失败跟被测功能毫无关系。
    expect(
      find.descendant(
        of: find.byKey(const Key('training-lesson-13')),
        matching: find.byIcon(Icons.check_circle),
      ),
      findsOneWidget,
      reason: '13 号课时 done=true，应显示实心对勾',
    );
    expect(
      find.descendant(
        of: find.byKey(const Key('training-lesson-12')),
        matching: find.byIcon(Icons.play_circle_outline),
      ),
      findsOneWidget,
      reason: '12 号课时没看完，应显示播放圈',
    );
  });

  /// 下载带鉴权头 —— 放在**纯 Dart 测试**里，不走 widget 的假时钟。
  ///
  /// 🔴 为什么不能放进 testWidgets：真 HttpClient 会挂一个 15 秒的空闲连接
  ///    定时器，而它注册在 fake_async 里，pump 不掉，测试末尾必然
  ///    报 "Pending timers"，且完全看不出跟下载有关。
  ///    纯 Dart 的 test() 用真时钟，没有这个问题。
  test('⑦ 课件下载带 Authorization 头并落盘', () async {
    final s2 = await ApiStub.start();
    final dir = await Directory.systemTemp.createTemp('xz-dl-test-');
    FileIo.dirOverride = dir;
    addTearDown(() async {
      FileIo.dirOverride = null;
      await s2.stop();
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });
    s2.on('GET', '/api/training/lessons/12/media', (r) => {'ok': true});

    final f = await FileIo.download(
      '${s2.baseUrl}/api/training/lessons/12/media',
      File('${dir.path}${Platform.pathSeparator}12_视频一.mp4'),
      headers: {'Authorization': 'Bearer tok'},
    );
    expect(await f.exists(), isTrue);
    final call = s2.last('GET', '/api/training/lessons/12/media');
    expect(call.authorization, 'Bearer tok', reason: '课件接口要鉴权，不带就是 401');
  });
}
