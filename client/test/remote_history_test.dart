import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/local_db.dart';
import 'package:xiaozhi_im_client/core/remote_history_store.dart';

/// 远程协助本地历史 + 收藏（龙哥 2026-10-16 需求）的测试。
///
/// 这一层盯的不是"能跑"，而是几个**错了也很难发现**的点：
///   · 同对象再连必须只累加次数、只占一行（不然列表越用越脏）；
///   · 🔴 再连一次**不许把用户的收藏冲掉**（这正是弃用
///     ConflictAlgorithm.replace 的原因 —— replace 是删旧插新）；
///   · 收藏置顶、清空默认保留收藏（用户点清空通常只想清普通记录）；
///   · 没拿到名字时不覆盖旧名字（防止把好名字冲成空）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
  final supportDir = '${Directory.systemTemp.path}/xz_remote_history_test';
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(pathChannel, (call) async {
    if (call.method == 'getApplicationSupportDirectory') return supportDir;
    return null;
  });

  setUp(() async {
    await LocalDb.I.resetForTest();
  });

  tearDown(() async {
    await LocalDb.I.close();
  });

  group('记录与累加', () {
    test('连一次记一行，字段落库正确', () async {
      await RemoteHistoryStore.I.record(
        peerId: 7,
        peerName: '老王',
        code: '',
        kind: 'friend',
      );
      final list = await RemoteHistoryStore.I.list();
      expect(list, hasLength(1));
      final h = list.first;
      expect(h.peerId, 7);
      expect(h.peerName, '老王');
      expect(h.kind, 'friend');
      expect(h.isCode, isFalse);
      expect(h.times, 1);
      expect(h.fav, isFalse);
      expect(h.lastAt, greaterThan(0));
      expect(h.title, '老王');
    });

    test('🔴 同对象再连只累加次数、不新增行，last_at 被推新', () async {
      await RemoteHistoryStore.I.record(
        peerId: 7, peerName: '老王', code: '', kind: 'friend',
      );
      // 把 last_at 拨到一天前，再连一次应当被刷新
      final db = await LocalDb.I.db();
      final stale = DateTime.now()
          .subtract(const Duration(days: 1))
          .millisecondsSinceEpoch;
      await db.update('remote_history', {'last_at': stale}, where: '1 = 1');

      await RemoteHistoryStore.I.record(
        peerId: 7, peerName: '老王', code: '', kind: 'friend',
      );

      final list = await RemoteHistoryStore.I.list();
      expect(list, hasLength(1), reason: '同对象再连不许多出一行');
      expect(list.first.times, 2);
      expect(list.first.lastAt, greaterThan(stale));
    });

    test('🔴 再连一次不许把收藏冲掉（replace 语义会犯的错）', () async {
      await RemoteHistoryStore.I.record(
        peerId: 7, peerName: '老王', code: '', kind: 'friend',
      );
      final first = (await RemoteHistoryStore.I.list()).first;
      await RemoteHistoryStore.I.setFav(first.id, true);

      // 同名同 id 再连三次
      for (var i = 0; i < 3; i++) {
        await RemoteHistoryStore.I.record(
          peerId: 7, peerName: '老王', code: '', kind: 'friend',
        );
      }

      final list = await RemoteHistoryStore.I.list();
      expect(list, hasLength(1));
      expect(list.first.fav, isTrue, reason: '收藏必须活过重复连接');
      expect(list.first.times, 4);
    });

    test('这次没拿到名字时不覆盖旧名字', () async {
      await RemoteHistoryStore.I.record(
        peerId: 7, peerName: '老王', code: '', kind: 'friend',
      );
      await RemoteHistoryStore.I.record(
        peerId: 7, peerName: '', code: '', kind: 'friend',
      );
      final list = await RemoteHistoryStore.I.list();
      expect(list, hasLength(1));
      expect(list.first.peerName, '老王');
    });

    test('同事与访问码是两条独立记录（同一个人两种连法）', () async {
      await RemoteHistoryStore.I.record(
        peerId: 7, peerName: '老王', code: '', kind: 'friend',
      );
      await RemoteHistoryStore.I.record(
        peerId: 7, peerName: '老王', code: '123456789', kind: 'code',
      );
      final list = await RemoteHistoryStore.I.list();
      expect(list, hasLength(2));
      final codeItem = list.firstWhere((e) => e.isCode);
      expect(codeItem.code, '123456789');
      expect(codeItem.title, '老王');
    });

    test('访问码记录没名字时兜底文案', () async {
      await RemoteHistoryStore.I.record(
        peerId: 7, peerName: '', code: '123456789', kind: 'code',
      );
      final list = await RemoteHistoryStore.I.list();
      expect(list.single.title, '访问码连接');
    });
  });

  group('收藏与排序', () {
    test('收藏置顶，其余按最近连接倒序', () async {
      await RemoteHistoryStore.I.record(
        peerId: 1, peerName: '甲', code: '', kind: 'friend',
      );
      await RemoteHistoryStore.I.record(
        peerId: 2, peerName: '乙', code: '', kind: 'friend',
      );
      await RemoteHistoryStore.I.record(
        peerId: 3, peerName: '丙', code: '', kind: 'friend',
      );
      // 收藏最早那条
      final first = (await RemoteHistoryStore.I.list())
          .firstWhere((e) => e.peerName == '甲');
      await RemoteHistoryStore.I.setFav(first.id, true);

      final list = await RemoteHistoryStore.I.list();
      expect(list.map((e) => e.peerName).toList(), ['甲', '丙', '乙']);
    });

    test('setFav 可反复切换', () async {
      await RemoteHistoryStore.I.record(
        peerId: 1, peerName: '甲', code: '', kind: 'friend',
      );
      final id = (await RemoteHistoryStore.I.list()).first.id;
      await RemoteHistoryStore.I.setFav(id, true);
      expect((await RemoteHistoryStore.I.list()).first.fav, isTrue);
      await RemoteHistoryStore.I.setFav(id, false);
      expect((await RemoteHistoryStore.I.list()).first.fav, isFalse);
    });
  });

  group('删除与清空', () {
    test('remove 只删指定那条', () async {
      await RemoteHistoryStore.I.record(
        peerId: 1, peerName: '甲', code: '', kind: 'friend',
      );
      await RemoteHistoryStore.I.record(
        peerId: 2, peerName: '乙', code: '', kind: 'friend',
      );
      final id = (await RemoteHistoryStore.I.list())
          .firstWhere((e) => e.peerName == '甲').id;
      await RemoteHistoryStore.I.remove(id);
      final list = await RemoteHistoryStore.I.list();
      expect(list, hasLength(1));
      expect(list.single.peerName, '乙');
    });

    test('🔴 清空默认保留收藏', () async {
      await RemoteHistoryStore.I.record(
        peerId: 1, peerName: '甲', code: '', kind: 'friend',
      );
      await RemoteHistoryStore.I.record(
        peerId: 2, peerName: '乙', code: '', kind: 'friend',
      );
      final favId = (await RemoteHistoryStore.I.list())
          .firstWhere((e) => e.peerName == '甲').id;
      await RemoteHistoryStore.I.setFav(favId, true);

      await RemoteHistoryStore.I.clear();

      final list = await RemoteHistoryStore.I.list();
      expect(list, hasLength(1));
      expect(list.single.peerName, '甲');
      expect(list.single.fav, isTrue);
    });

    test('clear(keepFav:false) 连收藏一起清', () async {
      await RemoteHistoryStore.I.record(
        peerId: 1, peerName: '甲', code: '', kind: 'friend',
      );
      final id = (await RemoteHistoryStore.I.list()).first.id;
      await RemoteHistoryStore.I.setFav(id, true);
      await RemoteHistoryStore.I.clear(keepFav: false);
      expect(await RemoteHistoryStore.I.list(), isEmpty);
    });
  });

  // 手动收藏：龙哥 2026-10-16 反馈"我要的收藏夹没有添加"。
  //
  // 关键在于**它不需要先连过一次** —— 之前的收藏只能靠历史行上的 ★，
  // 而历史行是"连过才生成"的，等于把收藏锁在了"已经连上"之后。
  group('手动收藏（addFavorite）', () {
    test('没连过也能收藏，times 落成 0（不能显示成"连过 0 次"）', () async {
      final ok = await RemoteHistoryStore.I.addFavorite(
        peerId: 0,
        peerName: '门店前台机器',
        code: '123456789',
        kind: 'code',
      );
      expect(ok, isTrue);
      final list = await RemoteHistoryStore.I.list();
      expect(list, hasLength(1));
      final h = list.first;
      expect(h.fav, isTrue);
      expect(h.times, 0);
      expect(h.isCode, isTrue);
      expect(h.code, '123456789');
      expect(h.title, '门店前台机器');
    });

    test('收藏同事账号：kind=friend、code 为空、peerId 有效', () async {
      await RemoteHistoryStore.I.addFavorite(
        peerId: 10086, peerName: '老王', code: '', kind: 'friend',
      );
      final h = (await RemoteHistoryStore.I.list()).single;
      expect(h.peerId, 10086);
      expect(h.kind, 'friend');
      expect(h.isCode, isFalse);
      expect(h.code, isEmpty);
    });

    test('同一个对象重复收藏只占一行，并且顺带更新备注名', () async {
      await RemoteHistoryStore.I.addFavorite(
        peerId: 7, peerName: '老王', code: '', kind: 'friend',
      );
      await RemoteHistoryStore.I.addFavorite(
        peerId: 7, peerName: '前台老王', code: '', kind: 'friend',
      );
      final list = await RemoteHistoryStore.I.list();
      expect(list, hasLength(1));
      expect(list.single.peerName, '前台老王');
    });

    test('把已连过的记录收藏起来：累加历史仍然保留（不重置 times）', () async {
      await RemoteHistoryStore.I.record(
        peerId: 7, peerName: '老王', code: '', kind: 'friend',
      );
      await RemoteHistoryStore.I.addFavorite(
        peerId: 7, peerName: '老王', code: '', kind: 'friend',
      );
      final list = await RemoteHistoryStore.I.list();
      expect(list, hasLength(1));
      expect(list.single.times, 1, reason: '收藏不能把连接次数清零');
      expect(list.single.fav, isTrue);
    });

    test('收藏排在非收藏前面（列表查询 fav DESC）', () async {
      await RemoteHistoryStore.I.record(
        peerId: 1, peerName: '普通', code: '', kind: 'friend',
      );
      await RemoteHistoryStore.I.addFavorite(
        peerId: 2, peerName: '收藏', code: '', kind: 'friend',
      );
      final list = await RemoteHistoryStore.I.list();
      expect(list.first.peerName, '收藏');
      expect(list.first.fav, isTrue);
      expect(list.last.fav, isFalse);
    });

    test('清空历史默认保留手动收藏', () async {
      await RemoteHistoryStore.I.addFavorite(
        peerId: 0, peerName: '机器', code: '123456789', kind: 'code',
      );
      await RemoteHistoryStore.I.record(
        peerId: 9, peerName: '临时', code: '', kind: 'friend',
      );
      await RemoteHistoryStore.I.clear();
      final list = await RemoteHistoryStore.I.list();
      expect(list, hasLength(1));
      expect(list.single.title, '机器');
    });
  });

  group('最近一次文案（remoteWhenText）', () {
    final now = DateTime(2026, 10, 16, 14, 30);

    String at(DateTime t) => remoteWhenText(t.millisecondsSinceEpoch, now: now);

    test('一分钟内是"刚刚"', () {
      expect(at(now.subtract(const Duration(seconds: 5))), '刚刚');
    });

    test('一小时内是"N 分钟前"', () {
      expect(at(now.subtract(const Duration(minutes: 25))), '25 分钟前');
    });

    test('当天是"今天 HH:mm"', () {
      expect(at(DateTime(2026, 10, 16, 9, 5)), '今天 09:05');
    });

    test('前一天是"昨天 HH:mm"', () {
      expect(at(DateTime(2026, 10, 15, 23, 59)), '昨天 23:59');
    });

    test('同年更早是"M 月 d 日"', () {
      expect(at(DateTime(2026, 8, 3, 10, 0)), '8 月 3 日');
    });

    test('跨年带年份', () {
      expect(at(DateTime(2025, 12, 31, 10, 0)), '2025-12-31');
    });
  });
}
