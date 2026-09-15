import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'remote_config.dart';

/// 服务器「工作区」身份：公司名 + 好友模式（普通 / 工作）。
///
/// 为什么单独做一层：`friendMode` 以前只在注册页读过一次，主界面根本不知道
/// 自己是工作模式 —— 于是所有功能只能平铺进一个「⋮」菜单，工作模式下同事想打卡
/// 要走「⋮ → 工作台」两步。**导航形态取决于这个值**（工作模式才给工作台/组织
/// 通讯录一级入口），所以它必须是能跨页面读、且变化时能通知 UI 重建的状态。
///
/// 两条纪律（与 RemoteConfig 一致）：
///   · 冷启动**先用上次缓存**决定导航，没网也不会退化成普通模式；
///   · 拉取失败**保持现状**，配置层出问题绝不影响正常使用。
class Workspace {
  static const _kMode = 'xz_friend_mode';
  static const _kName = 'xz_company_name';

  static const normal = 'normal';
  static const work = 'work';

  /// 当前好友模式（'normal' / 'work'）。改它请走 [apply]，会落盘并通知监听者。
  static final ValueNotifier<String> mode = ValueNotifier<String>(normal);

  /// 当前公司名（登录页标题、局域网扫描结果用得到）
  static final ValueNotifier<String> company = ValueNotifier<String>('');

  /// 是否工作模式。**导航与入口可见性都读它**，不要在别处再判一次字符串。
  static bool get isWork => mode.value == work;

  /// 冷启动调用：先把缓存读出来（离线也能定导航），再后台拉最新的。
  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    mode.value = p.getString(_kMode) ?? normal;
    company.value = p.getString(_kName) ?? '';
    // 不 await：拿到最新值会通过 mode/company 通知 UI 自行重建，
    // 卡在这里等于让启动等一次网络往返
    refresh();
  }

  /// 拉一次 bootstrap 的公开字段并落盘。任何失败静默（保持现状）。
  ///
  /// **失败重试**：冷启动时这一发请求若因地址还没解析好 / 网络抖动失败，
  /// 静默错过会让客户端卡在旧模式 —— 导航不切工作模式，工作台 / 组织通讯录
  /// 这两个一级入口就永远出不来（已入编员工也点不进去）。所以这里最多重试 2 次，
  /// 退避 2s，给地址探测 / 网络恢复留出时间。
  static Future<void> refresh() async {
    for (var attempt = 0; attempt < 3; attempt++) {
      final b = await RemoteConfig.fetchPublic();
      if (b.isNotEmpty) {
        await apply(
          mode: (b['friendMode'] ?? '').toString(),
          companyName: (b['companyName'] ?? '').toString(),
        );
        return;
      }
      if (attempt < 2) {
        await Future.delayed(Duration(seconds: 2 * (attempt + 1)));
      }
    }
  }

  /// 应用一份身份信息。空值/非法值**跳过该项**，不覆盖已有状态。
  static Future<void> apply({String? mode, String? companyName}) async {
    final p = await SharedPreferences.getInstance();
    final m = mode;
    // 白名单：**只有** normal / work 两个值会被写进来，未知值一律忽略。
    //
    // 为什么是"忽略"而不是"当成普通模式"：服务端将来若加第三种模式，把它降级成
    // 普通模式会让正在用工作模式的人**当场丢掉打卡入口**（比保留现状糟得多）。
    // 保持现状最多是"界面没跟上"，不会让人找不到每天要用的东西。
    // 所以这里的不变量是"状态只能是这两个值之一"，而不是"未知值→normal"。
    //
    // ⚠️ 必须先判 null：`m == work` 这种**等值比较不会做类型提升**，
    // 少了 m != null 的话 m 在分支里仍是 String?，赋给 ValueNotifier<String> 直接编译不过。
    if (m != null && (m == normal || m == work)) {
      if (m != Workspace.mode.value) {
        Workspace.mode.value = m;
        await p.setString(_kMode, m);
      }
    }
    final n = companyName;
    if (n != null && n.isNotEmpty && n != Workspace.company.value) {
      Workspace.company.value = n;
      await p.setString(_kName, n);
    }
  }

  const Workspace._();
}
