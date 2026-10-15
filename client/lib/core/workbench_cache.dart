// 工作台本地缓存（离线可用）
//
// 【为什么要有它】
// 龙哥 2026-10-15 报的场景：外网网络差时打开工作台，直接弹
// "拿不到应用列表 连接超时"，连不需要联网的应用（简易盘点、商档查询这类
// 本地库功能）都进不去。而工作台的应用清单/分组/公告**变化很慢**——
// 管理员改一次管很久。为一次清单刷新拦住所有本地功能，不划算。
//
// 【策略】
//   · 打开页面：先读缓存立刻渲染（不等网络），同时后台静默刷新；
//   · 刷新成功：更新缓存，界面无感换新；
//   · 刷新失败：有缓存就继续显示缓存（顶部小字提示"网络不稳，显示缓存数据"），
//     不给错误页；没有缓存（首次安装/清过数据）才显示错误 + 重试。
//
// 【缓存键按企业分】多企业切换时每个 profile 一份，切过去立刻有画面。
//
// 【存什么】只存"展示用"的最终清单（服务端下发再经客户端过滤后的），
// 不存原始响应 —— 将来服务端加字段老缓存也不会带出新格式问题。

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class WorkbenchCache {
  WorkbenchCache._();
  static final WorkbenchCache instance = WorkbenchCache._();

  static const _prefix = 'workbench_cache_v1_';

  String _key(String profileId) => '$_prefix$profileId';

  /// 读缓存。没有/损坏返回 null（损坏按没有处理：坏数据不该拦住正常刷新）。
  Future<Map<String, dynamic>?> read(String profileId) async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_key(profileId));
      if (raw == null || raw.isEmpty) return null;
      final d = jsonDecode(raw);
      if (d is! Map) return null;
      return Map<String, dynamic>.from(d);
    } catch (_) {
      return null;
    }
  }

  /// 写缓存。三段清单 + 时间戳。写失败无所谓（下次刷新会盖）。
  Future<void> write(
    String profileId, {
    required List<Map<String, dynamic>> apps,
    required List<Map<String, dynamic>> groups,
    required List<Map<String, dynamic>> notices,
  }) async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(
        _key(profileId),
        jsonEncode(<String, dynamic>{
          'ts': DateTime.now().millisecondsSinceEpoch,
          'apps': apps,
          'groups': groups,
          'notices': notices,
        }),
      );
    } catch (_) {
      /* 缓存写不进不影响功能，静默 */
    }
  }
}
