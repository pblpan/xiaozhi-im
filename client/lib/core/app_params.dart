// 应用参数（管理台「应用中心」里配的那些）。
//
// ── 为什么要有这一层 ───────────────────────────────────────
// 有些值**各家门店不一样**，写死在代码里必然出错（电子秤码的商品码位数
// 就是典型：泰格是 5 位，别的软件可能是 4 位或 6 位）。
// 服务端已经把这些参数随 `/api/client/apps` 下发下来了（apps.js 的 params），
// 但客户端原来**没人读它** —— 于是管理台上改了没效果。
// 这一层就是"读它"的地方。
//
// 🔴 纪律：只在这里登记**真的有代码在读**的参数。
//    登记一个没人读的参数，比没有这个参数更糟 —— 管理员改完发现没效果，
//    就再也不信这个页面上的任何东西了（服务端 appoverrides.js 里同一条纪律）。
//
// ── 拿不到时怎么办 ─────────────────────────────────────────
// **一律用默认值继续跑**，不弹错、不拦住业务。
// 离线、没登录、服务端是旧版本（还没有 params 字段）都会走到这条路，
// 而电子秤码解析错了还有"解不出来就当普通条码"这一层兜着，
// 最坏也只是回到参数化之前的行为 —— 不会因为拿不到参数就扫不了码。

import '../api.dart';
import 'scale_code.dart';

class AppParams {
  AppParams._();

  static final AppParams I = AppParams._();

  int _scaleCodeLen = ScaleCode.defaultCodeLen;
  bool _loaded = false;

  /// 电子秤码里"商品码"占几位（泰格 5 位）。管理台可改。
  int get scaleCodeLen => _scaleCodeLen;

  /// 拉一次服务端下发的参数。失败**静默**用默认值（理由见文件头）。
  ///
  /// 页面在 initState 里调它就行，不必等它 —— 等它的话弱网时进页面会卡住。
  Future<void> refresh() async {
    try {
      final res = await ImApi().clientApps();
      final raw = res['apps'] ?? res['items'] ?? res;
      if (raw is! List) return;
      for (final a in raw) {
        if (a is! Map) continue;
        if ((a['id'] ?? '').toString() != 'replenish') continue;
        final p = a['params'];
        if (p is! Map) continue;
        final n = p['scaleCodeLen'];
        // 管理台配出来的一定是 int（appoverrides.js 的 int 校验带 min/max），
        // 但旧服务端可能下发字符串 —— 宽松解析，配错了就退回默认 5。
        final v = n is num ? n.toInt() : int.tryParse(n.toString());
        if (v != null && v >= 3 && v <= 8) _scaleCodeLen = v;
      }
      _loaded = true;
    } catch (_) {
      // 离线 / 未登录 / 服务端旧版本：保持默认值。不记日志、不打扰用户。
    }
  }

  /// 测试用：直接指定（不起服务端）。
  static void debugSetScaleCodeLen(int v) {
    I._scaleCodeLen = v;
    I._loaded = true;
  }

  /// 参数是不是真的从服务端读到过（界面上要区分"配了 5"和"没读到用 5"吗？
  /// 目前不需要，留着给以后要显示"当前生效值"的地方用）。
  bool get loaded => _loaded;
}
