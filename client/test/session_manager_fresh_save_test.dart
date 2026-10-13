import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xiaozhi_im_client/core/config.dart';
import 'package:xiaozhi_im_client/core/server_profile.dart';
import 'package:xiaozhi_im_client/core/session_manager.dart';
import 'package:xiaozhi_im_client/core/settings.dart';

/// 全新安装后保存服务器地址 —— 龙哥 2026-10-13 实测：
/// 外网手工输入地址，服务器设置里点保存**毫无反应**。
///
/// 根因：`SessionManager.profiles` 在"无旧键 + 局域网扫描无果"时会留在
/// **不可变列表**（`const []`，来自 `_migrateFromLegacy` 的空返回），
/// 而保存走 `Settings.setServers` → 首启分支 → `addProfile` →
/// `profiles.add()` 对不可变列表抛 `UnsupportedError`；保存链上没人接异常，
/// 弹窗不关、不提示、不落盘 —— 最难查的"静默失败"。
/// 升级用户走 `updateAddresses`（只改对象字段）所以从未暴露。
///
/// 这三个用例把三件事钉死：
/// ① load() 之后 profiles 必须可写（不变量本身）；
/// ② `Settings.setServers` 在全新安装上真的能存下第一家服务器并落盘；
/// ③ 存完激活项 / Config 镜像都对（不然存了也连不上）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 让所有出网请求立刻失败：本用例不关心 bootstrap 内容，
  // 只关心"不卡在真实网络上"。floating 的 Workspace.refresh 会重试 3 次
  // （0s / +2s / +4s），用例尾部统一等够时间再收尾。
  HttpOverrides.global = _FailFastOverrides();

  const lan = 'http://192ff4e040e3b.hn.takir';

  /// 🔴 SharedPreferences.getInstance() 是**进程内单例**：setMockInitialValues
  ///    只对"还没建过实例"的进程有效。前一个用例写进 mock store 的服务器
  ///    档案会漏进后一个用例（CI 2026-10-13 上 ② 看到 ① 的档案、
  ///    isEmpty 挂掉的根因）。所以每个用例开头都要手动清一次。
  Future<void> freshPrefs() async {
    SharedPreferences.setMockInitialValues({});
    final sp = await SharedPreferences.getInstance();
    await sp.clear();
    // SessionManager 是单例，上一用例可能已经给它塞了内存档案 —— 一并清。
    // 🔴 activeId 也要清：留着的话 setServers 看到"有激活档案"就走
    //    updateAddresses 分支，而 profiles 是空的 → _find 返回 null →
    //    什么都没干 → length 0（CI 二轮 ③ 的 Actual 0 就是它）。
    SessionManager.instance.profiles = [];
    SessionManager.instance.activeId = null;
  }

  test('① 全新安装：load() 之后 profiles 必须可写', () async {
    await freshPrefs();
    final sm = SessionManager.instance;
    await sm.load(); // 无旧键、扫描扫不到 → 空档案（真实环境约 4s）
    expect(sm.profiles, isEmpty);
    // 🔴 修复前这里是 UnsupportedError: Cannot add to an unmodifiable list
    sm.profiles.add(ServerProfile(
      id: ServerProfile.newId(),
      name: '小智',
      lan: lan,
      wan: '',
      mode: Config.modeAuto,
    ));
    expect(sm.profiles.length, 1);
  });

  test('② 全新安装：Settings.setServers 存得下第一家服务器', () async {
    await freshPrefs();
    final sm = SessionManager.instance;
    await sm.load();
    expect(sm.profiles, isEmpty);
    expect(sm.activeId, isNull);

    // 弹窗「保存」按钮走的就是这一句
    await Settings.setServers(lan: lan, wan: '', mode: Config.modeAuto);

    expect(sm.profiles.length, 1);
    expect(sm.activeId, sm.profiles.first.id);
    expect(sm.profiles.first.lan, lan);
    // 落盘了（重开 App 读得回来）
    final raw = (await SharedPreferences.getInstance())
        .getString('xz_profiles') ?? '';
    expect(raw, contains('192ff4e040e3b.hn.takir'));
    // Config 镜像（连接就靠它）
    expect(Config.lanUrl, lan);

    // 等 floating 的 Workspace.refresh 重试跑完，避免 pending timer
    await Future<void>.delayed(const Duration(seconds: 8));
  });

  test('③ 已有档案时改地址仍然只走 updateAddresses（不回退）', () async {
    await freshPrefs();
    final sm = SessionManager.instance;
    await sm.load();
    await Settings.setServers(lan: lan, wan: '', mode: Config.modeAuto);
    final id = sm.activeId!;
    // 升级用户路径：改地址不该新增档案
    await sm.updateAddresses(id, 'http://10.0.0.9:3602', '', Config.modeWan);
    expect(sm.profiles.length, 1);
    expect(Config.lanUrl, 'http://10.0.0.9:3602');
    expect(Config.mode, Config.modeWan);
    await Future<void>.delayed(const Duration(seconds: 8));
  });
}

/// 出网一律瞬间失败的 HttpOverrides。
class _FailFastOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return super.createHttpClient(context)
      ..connectionTimeout = const Duration(milliseconds: 1);
  }
}
