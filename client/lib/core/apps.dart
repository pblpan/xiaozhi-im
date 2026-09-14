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
import '../screens/attendance_request.dart';
import '../screens/org_screen.dart';

/// 内置应用 id 清单（与服务端 apps.js 的 BUILTIN_APPS 一一对应）
const kBuiltinAppIds = {'attendance', 'my_requests', 'work_org'};

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
    default:
      return null;
  }
}
