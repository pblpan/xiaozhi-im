/// 远程协助的「本地历史 + 收藏」。
///
/// ─────────────────────────────────────────────────────────────
/// 为什么本地还要一份历史，服务端不是已经有「协助记录」了吗
/// ─────────────────────────────────────────────────────────────
/// 服务端那份是**审计**：回答"谁在什么时候连了谁"，字段全、不能改、
/// 删不得。但它回答不了龙哥要的那件事 —— 「方便下次发起连接」。
/// 想再连一次门店前台那台，难道要去审计列表里翻出上次的 9 位码？
///
/// 这份本地记录就干这一件事：把**我发起的**连接（同事 / 访问码）记下来，
/// 收藏置顶，点一下直接再发起。所以它：
///   · 只记控制端视角（被控来的连接服务端审计里有，不重复记）；
///   · 用户有权删单条、清空（审计不行）；
///   · 连过 N 次只占一行（同对象累加，不是每次都插一行新的）。
///
/// ─────────────────────────────────────────────────────────────
/// 访问码为什么也存
/// ─────────────────────────────────────────────────────────────
/// 无人值守的重连只能靠码 —— 不存码，"一键重连"对无人值守就是句空话。
/// 码只落本机 SQLite，不上传、不打日志；要泄漏至少得先拿到这台手机，
/// 而这把钥匙本来就在这台手机上用。
library;

import 'local_db.dart';

/// 一条本地历史 / 收藏。
class RemoteHistoryItem {
  const RemoteHistoryItem({
    required this.id,
    required this.peerId,
    required this.peerName,
    required this.code,
    required this.kind,
    required this.times,
    required this.fav,
    required this.lastAt,
  });

  final int id;
  final int peerId; // 对方账号 ID（访问码连接时是被控机器的属主）
  final String peerName;
  final String code; // 仅 kind=='code' 时非空
  final String kind; // 'friend' 同事协助 | 'code' 访问码无人值守
  final int times; // 连过几次
  final bool fav; // 收藏置顶
  final int lastAt; // 最近一次连接时间（毫秒）

  bool get isCode => kind == 'code';

  /// 列表主标题。名字优先；没名字（服务端没给）按连接方式兜底。
  String get title =>
      peerName.isNotEmpty ? peerName : (isCode ? '访问码连接' : '同事');
}

/// 本地历史 + 收藏的仓库。失败一律当"没有"——
/// 历史读不出来顶多是没法一键重连，绝不能因此把远程页搞崩。
class RemoteHistoryStore {
  RemoteHistoryStore._();

  static final RemoteHistoryStore I = RemoteHistoryStore._();

  static const String _t = 'remote_history';

  /// 全部记录：**收藏在前**，其余按最近连接倒序。
  Future<List<RemoteHistoryItem>> list() async {
    try {
      final db = await LocalDb.I.db();
      final rows = await db.query(_t, orderBy: 'fav DESC, last_at DESC');
      return rows.map(_fromRow).toList();
    } catch (_) {
      return const [];
    }
  }

  /// 连过一次就记一笔。同对象（kind + peer_id + code 全同）只累加次数、
  /// 更新时间，**不动收藏**；名字以最新一次为准（对方可能改了昵称），
  /// 但这次没拿到名字时不覆盖旧的（防止把好名字冲掉）。
  Future<void> record({
    required int peerId,
    required String peerName,
    required String code,
    required String kind,
  }) async {
    try {
      final db = await LocalDb.I.db();
      final now = DateTime.now().millisecondsSinceEpoch;
      final rows = await db.query(
        _t,
        where: 'kind = ? AND peer_id = ? AND code = ?',
        whereArgs: <Object?>[kind, peerId, code],
        limit: 1,
      );
      if (rows.isEmpty) {
        await db.insert(_t, <String, Object?>{
          'peer_id': peerId,
          'peer_name': peerName,
          'code': code,
          'kind': kind,
          'times': 1,
          'fav': 0,
          'last_at': now,
        });
        return;
      }
      await db.update(
        _t,
        <String, Object?>{
          'times': ((rows.first['times'] as int?) ?? 1) + 1,
          'last_at': now,
          if (peerName.isNotEmpty) 'peer_name': peerName,
        },
        where: 'id = ?',
        whereArgs: <Object?>[rows.first['id'] as int],
      );
    } catch (_) {
      // 记一笔历史失败不该影响正在进行的远程协助，吞掉
    }
  }

  Future<void> setFav(int id, bool fav) async {
    try {
      final db = await LocalDb.I.db();
      await db.update(_t, <String, Object?>{'fav': fav ? 1 : 0},
          where: 'id = ?', whereArgs: <Object?>[id]);
    } catch (_) {}
  }

  Future<void> remove(int id) async {
    try {
      final db = await LocalDb.I.db();
      await db.delete(_t, where: 'id = ?', whereArgs: <Object?>[id]);
    } catch (_) {}
  }

  /// 清空历史。默认**保留收藏** —— 用户点"清空"通常是想清掉那一长串
  /// 普通记录，把收藏的一起清了得让他重新逐个加回来。
  Future<void> clear({bool keepFav = true}) async {
    try {
      final db = await LocalDb.I.db();
      if (keepFav) {
        await db.delete(_t, where: 'fav = 0');
      } else {
        await db.delete(_t);
      }
    } catch (_) {}
  }

  RemoteHistoryItem _fromRow(Map<String, Object?> r) => RemoteHistoryItem(
        id: (r['id'] as int?) ?? 0,
        peerId: (r['peer_id'] as int?) ?? 0,
        peerName: (r['peer_name'] ?? '').toString(),
        code: (r['code'] ?? '').toString(),
        kind: (r['kind'] ?? 'friend').toString(),
        times: (r['times'] as int?) ?? 1,
        fav: (r['fav'] as int?) == 1,
        lastAt: (r['last_at'] as int?) ?? 0,
      );
}

String _two(int n) => n.toString().padLeft(2, '0');

/// 历史列表里"最近一次"的文案。
///
/// 抽成顶层纯函数（now 可注入）是为了能单测 —— 时间文案是最容易
/// 在跨天/跨月边界上写错、又最容易被忽略的一块。
String remoteWhenText(int ms, {DateTime? now}) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  final n = now ?? DateTime.now();
  final diff = n.difference(t);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
  final d0 = DateTime(n.year, n.month, n.day);
  final d1 = DateTime(t.year, t.month, t.day);
  final days = d0.difference(d1).inDays;
  if (days == 0) return '今天 ${_two(t.hour)}:${_two(t.minute)}';
  if (days == 1) return '昨天 ${_two(t.hour)}:${_two(t.minute)}';
  if (t.year == n.year) return '${t.month} 月 ${t.day} 日';
  return '${t.year}-${_two(t.month)}-${_two(t.day)}';
}
