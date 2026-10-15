/// 价签模板的本地仓库。
///
/// ─────────────────────────────────────────────────────────────
/// 为什么模板存本地而不是服务端下发
/// ─────────────────────────────────────────────────────────────
/// 价签打印是**只剩手机也能干**的活：现场可能在仓库最里侧、信号全无，
/// 而打价签那会儿偏偏就是最急着要标签的时候。模板跟着打印功能一起
/// 落在手机上，断网照样选、照样打。
///
/// 服务端那份（如果有）是"总部统一发的模板"，本地这份是"这家店自己调过的"，
/// 两者是**叠加**关系不是覆盖关系：下发的在前，本地另存的在后，
/// 内置 6 套永远在最前面。
///
/// ─────────────────────────────────────────────────────────────
/// 失败一律当"没有"，绝不让打印页打不开
/// ─────────────────────────────────────────────────────────────
/// 模板读不出来（表还没建 / 迁移没跑到 / 磁盘满）时，返回**内置模板列表**。
/// 读不到模板的后果顶多是"只能选那 6 套内置的"，而抛异常的后果是
/// 打印页直接白屏 —— 人在现场等着打标签，白屏比选择少糟糕一万倍。
library;

import 'dart:convert';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'local_db.dart';
import 'price_tag_template.dart';

/// 键值表里存"上次选择的模板 id"用的键。
const String _kLast = 'last_template';

class PriceTagStore {
  PriceTagStore._();

  static final PriceTagStore I = PriceTagStore._();

  /// 全部模板：内置 6 套 + 用户自己存的（按更新时间倒序）。
  ///
  /// 永远**先内置后自建**：内置的排序是固定的，自建的才有先后。
  Future<List<PriceTagTemplate>> list() async {
    final out = List<PriceTagTemplate>.from(kBuiltinTagTemplates);
    try {
      final db = await LocalDb.I.db();
      final rows = await db.query(
        'price_tag_template',
        orderBy: 'updated_at DESC',
      );
      for (final r in rows) {
        Object? decoded;
        try {
          decoded = jsonDecode((r['json'] ?? '').toString());
        } catch (_) {
          continue; // 一条坏 JSON 跳过，不影响其它模板能用
        }
        final t = PriceTagTemplate.fromJson(decoded);
        if (t == null) continue;
        // 🔴 用户模板若与内置 id 撞了，以内置为准 ——
        //    否则用户存一个 id 叫 builtin_standard 的模板，
        //    界面上会出现两个"标准价签"，删掉哪个都不对。
        if (out.any((b) => b.id == t.id)) continue;
        out.add(t);
      }
    } catch (_) {
      // 读不出来就只给内置的那几套
    }
    return out;
  }

  Future<PriceTagTemplate?> byId(String id) async {
    for (final t in kBuiltinTagTemplates) {
      if (t.id == id) return t;
    }
    try {
      final db = await LocalDb.I.db();
      final rows = await db.query(
        'price_tag_template',
        where: 'id = ?',
        whereArgs: <Object?>[id],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      return PriceTagTemplate.fromJson(jsonDecode(rows.first['json'].toString()));
    } catch (_) {
      return null;
    }
  }

  /// 存一个模板（新建或覆盖）。**内置模板必须先另存为新 id** ——
  /// 改内置模板等于把所有人手机上的"标准价签"悄悄换掉，而他们没同意。
  Future<void> save(PriceTagTemplate t) async {
    if (t.builtin) return;
    final db = await LocalDb.I.db();
    await db.insert(
      'price_tag_template',
      <String, Object?>{
        'id': t.id,
        'name': t.name,
        'json': jsonEncode(t.toJson()),
        'updated_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> remove(String id) async {
    // 内置模板删不掉：删光了打印页就没有可用模板
    if (id.startsWith('builtin_')) return;
    final db = await LocalDb.I.db();
    await db.delete(
      'price_tag_template',
      where: 'id = ?',
      whereArgs: <Object?>[id],
    );
  }

  /// 记住上次选的模板（下次进打印页直接选中它 —— 一天之内打的都是同一批货架）。
  Future<void> setLast(String id) => _set(_kLast, id);

  Future<String> last() async => await _get(_kLast) ?? kDefaultTemplateId;

  Future<void> _set(String k, String v) async {
    try {
      final db = await LocalDb.I.db();
      await db.insert(
        'price_tag_kv',
        <String, Object?>{'k': k, 'v': v},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (_) {
      // 记不住偏好不是错误，下次进去选一下就是了
    }
  }

  Future<String?> _get(String k) async {
    try {
      final db = await LocalDb.I.db();
      final rows = await db.query(
        'price_tag_kv',
        where: 'k = ?',
        whereArgs: <Object?>[k],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      final v = rows.first['v']?.toString();
      return (v == null || v.isEmpty) ? null : v;
    } catch (_) {
      return null;
    }
  }
}

/// 造一个用户模板的新 id。
///
/// 用时间戳而不是随机 uuid：uuid 在本机还得引依赖，而时间戳 + 序号
/// 已经足够区分"同一个人在同一台手机上另存的几份"。
String newTemplateId() => 'u${DateTime.now().millisecondsSinceEpoch}';
