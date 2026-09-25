// 客户端「工作台」的内置应用注册表
//
// ─────────────────────────────────────────────────────────────
// 这一层是干什么的
// ─────────────────────────────────────────────────────────────
// 客户端的应用中心有两类应用，在同一个工作台里并列显示：
//
//   内置应用（本文件）  随安装包发布、有真实数据与业务逻辑的功能（考勤是第一个）
//   动态模块           管理台拼 JSON 出来、服务端下发的页面（第三期已上线）
//
// 服务端（server/src/apps.js）只下发 id / 标题 / 图标 / 分组，
// **页面由客户端注册** —— 服务端不可能下发 Dart 代码。所以这里是一张
// id → 页面构造器 的表。
//
// ─────────────────────────────────────────────────────────────
// 两条纪律
// ─────────────────────────────────────────────────────────────
// 1. **id 必须与 server/src/apps.js 完全一致，且发布后不可改名**
//    （改名等于老客户端丢入口）。
// 2. **不认识的 id 一律返回 null，工作台跳过它**。这是"服务端新增应用
//    不必先升级客户端"的机制：老客户端少一个图标，但不白屏、不报错。
//    Flutter 生态下没有"热更新 Dart 代码"这条路（既违规也不稳），
//    所以新增内置应用必须发版；能靠下发解决的只有动态模块 —— 这条边界
//    要一直清楚，别指望某天"下发一个新页面就能长出考勤"。

import 'package:flutter/material.dart';

import '../screens/attendance.dart';
import '../screens/attendance_admin.dart';
import '../screens/attendance_request.dart';
import '../screens/deduct.dart';
import '../screens/inventory.dart';
import '../screens/org_screen.dart';
import '../screens/simple_stocktake.dart';
import '../screens/stocktake.dart';
import '../screens/training.dart';

/// 内置应用 id 清单（与服务端 apps.js 的 BUILTIN_APPS 一一对应）
///
/// 🔴 **加一个内置应用要同步改五处**（漏一处就是"装了却看不到入口"，
///    而且服务端那两处有自检测试会拦，客户端这一处漏了只是静默不显示）：
///    ① 这里 `kBuiltinAppIds`
///    ② 下面的 `builtinAppPage` 路由
///    ③ `server/src/apps.js` 的 `BUILTIN_APPS`
///    ④ `server/src/appguard.js`：有服务端接口就进 `RULES`，纯离线就进 `LOCAL_ONLY`
///    ⑤ `server/src/appdata.js` 的 `APPS`（纯离线也要登记，写明"为什么没有数据"）
///    ＋ `client/test/module_schema_test.dart` 里那份期望集合（不加就变红）。
///
/// ⚠️ **发布后 id 不可改名**（改名等于老客户端丢入口）。
///
/// `attendance` / `my_requests` 是**员工专属**（自己打卡、自己提申请）；
/// `att_admin` 是**管理员专属**（今日看板 + 代补卡）。谁看得见由服务端按角色
/// 算好下发（server/src/apps.js 的 listFor），客户端只负责认不认得这个 id。
///
/// ⚠️ `stocktake`（扫码枪）与 `inventory`（盘点）是**两个不同的应用**，
/// 名字很容易看混 —— 区分见 `docs/盘点复刻与开放接口方案-v1.md` §3.0：
/// 扫码枪是"把条码扫成一笔账"的工具；盘点有盘点位、货架位与三遍制。
///
/// ⚠️ `inventory`（盘点）与 `simple_stocktake`（简易盘点）也是**两个不同的应用**：
/// 盘点是**制度型**（点位/货架位/三遍互比）；简易盘点是**干活型**
/// （导入这一轮要盘的清单 → 一趟趟扫 → 导出一张全量单）。
/// 两者并存、互不改动，见 `docs/简易盘点通道方案-v1.md` §1。
const kBuiltinAppIds = {
  'attendance',
  'my_requests',
  'work_org',
  'att_admin',
  'stocktake',
  'inventory',
  'simple_stocktake',
  'warehouse_deduct',
  'training',
};

/// 该 id 是否是本客户端认识的内置应用。
/// 服务端下发了但这里不认识 → 工作台直接不显示（而不是显示一个点进去崩的图标）。
bool isKnownBuiltinApp(String id) => kBuiltinAppIds.contains(id);

/// id → 页面。不认识的 id 返回 null（调用方负责跳过）。
Widget? builtinAppPage(String id) {
  switch (id) {
    case 'attendance':
      return const AttendancePage();
    case 'my_requests':
      return const AttendanceRequestPage();
    case 'work_org':
      return const OrgScreen();
    case 'att_admin':
      return const AttendanceAdminPage();
    case 'stocktake':
      return const StocktakePage();
    case 'inventory':
      return const InventoryPage();
    case 'simple_stocktake':
      return const SimpleStocktakePage();
    case 'warehouse_deduct':
      return const DeductPage();
    case 'training':
      return const TrainingPage();
    default:
      return null;
  }
}
