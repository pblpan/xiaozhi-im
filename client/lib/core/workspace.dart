import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../socket.dart';
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
  static const _kPrice = 'xz_master_show_purchase_price';

  static const normal = 'normal';
  static const work = 'work';

  /// 当前好友模式（'normal' / 'work'）。改它请走 [apply]，会落盘并通知监听者。
  static final ValueNotifier<String> mode = ValueNotifier<String>(normal);

  /// 当前公司名（登录页标题、局域网扫描结果用得到）
  static final ValueNotifier<String> company = ValueNotifier<String>('');

  /// 商档查询页要不要显示「进货价」（服务端管理台可配，默认不给看）。
  /// 进价是成本信息 —— 默认关，门店要用时管理台打开，改完即时推给在线客户端。
  static final ValueNotifier<bool> masterShowPurchasePrice =
      ValueNotifier<bool>(false);

  /// 展示用品牌名：有公司名 →「好又多小智」，没有 →「小智 IM」。
  ///
  /// ⚠️ **UI 一律监听它，别自己读 company 再拼一次**。之前登录页自己拼
  /// `'$name小智'`、主界面标题却写死 `'小智 IM'`，结果管理台改了公司名，
  /// 登录页变了、登进去又变回来 —— 看着像"改了没生效"，其实是两处规则分叉。
  /// 显示规则只能有一处定义。
  static final ValueNotifier<String> brand =
      ValueNotifier<String>(brandOf(''));

  /// 品牌名拼装规则（唯一真源）。服务端只存公司原文，前缀后缀在客户端拼。
  static String brandOf(String name) {
    final n = name.trim();
    return n.isEmpty ? '小智 IM' : '$n小智';
  }

  /// 是否工作模式。**导航与入口可见性都读它**，不要在别处再判一次字符串。
  static bool get isWork => mode.value == work;

  /// 冷启动调用：先把缓存读出来（离线也能定导航），再后台拉最新的。
  static Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    mode.value = p.getString(_kMode) ?? normal;
    company.value = p.getString(_kName) ?? '';
    brand.value = brandOf(company.value);
    masterShowPurchasePrice.value = p.getBool(_kPrice) ?? false;
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
          // 缺字段传 null（= 不覆盖）。**别写成 `?? ''`**：那等于把"没拿到"
          // 说成"服务端要清空"，一次网络抖动就把公司名抹了。
          companyName:
              b.containsKey('companyName') ? b['companyName'].toString() : null,
          showPurchasePrice: b.containsKey('masterShowPurchasePrice')
              ? b['masterShowPurchasePrice'] == true
              : null,
        );
        return;
      }
      if (attempt < 2) {
        await Future.delayed(Duration(seconds: 2 * (attempt + 1)));
      }
    }
  }

  /// 应用一份身份信息。每项传 `null` = **这次没拿到**（保持现状），
  /// 非 null（含空串） = 服务端明确了值。
  static Future<void> apply({
    String? mode,
    String? companyName,
    bool? showPurchasePrice,
  }) async {
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
    // 公司名：`null` = 这次没拿到这项（保持现状），`''` = 服务端明确清空（要落下去）。
    //
    // 为什么必须区分：老代码直接把 `b['companyName'] ?? ''` 传进来，于是"没拿到"
    // 和"服务端就是空"长得一模一样。为了不被网络抖动清掉公司名，只能加
    // `n.isNotEmpty` 才写 —— 代价是**管理台清空公司名永远不生效**。
    // 现在由调用方用 `containsKey` 把"缺字段"传成 null，两边就都能表达了。
    final n = companyName;
    if (n != null) {
      final v = n.trim();
      if (v != Workspace.company.value) {
        Workspace.company.value = v;
        // brand 是 company 的派生值，**必须同一处更新**，否则又出现两套规则
        brand.value = brandOf(v);
        await p.setString(_kName, v);
      }
    }
    // 显示进价开关：布尔量没有"空串"歧义，true/false 都是服务端明确的意思，
    // 只有 null（这次没拿到）保持现状。
    if (showPurchasePrice != null &&
        showPurchasePrice != masterShowPurchasePrice.value) {
      masterShowPurchasePrice.value = showPurchasePrice;
      await p.setBool(_kPrice, showPurchasePrice);
    }
  }

  /// 订阅服务端推来的设置变更（`settings:changed`），做到"管理台改完当场生效"。
  ///
  /// 为什么要这条通道：公司名 / 好友模式是**全服务生效**的，管理台一改，
  /// 所有开着的 App 都该跟着变。只靠 [refresh] 的话要等冷启动或切后台回前台 ——
  /// 用户在前台盯着就是"改了没反应"（龙哥 2026-09-18 报的正是这个）。
  ///
  /// 幂等：main() 启动时调一次即可，重复调用不会重复订阅。
  /// 流本身是 broadcast，订阅后才有帧；漏掉的那几帧由 [refresh] 兜底。
  static bool _socketBound = false;

  static void bindSocket() {
    if (_socketBound) return;
    _socketBound = true;
    SocketService().stream.listen((e) {
      if (e is! Map) return;
      if (e['type'] != 'settings:changed') return;
      // 与服务端 PUT /admin/settings 的载荷一一对应；缺字段传 null（= 不覆盖），
      // 判据和 [refresh] 完全一致，避免两条通道对同一份数据有两种解释。
      apply(
        mode: e['friendMode']?.toString(),
        companyName:
            e.containsKey('companyName') ? e['companyName']?.toString() : null,
        showPurchasePrice: e.containsKey('masterShowPurchasePrice')
            ? e['masterShowPurchasePrice'] == true
            : null,
      );
    });
  }

  const Workspace._();
}
