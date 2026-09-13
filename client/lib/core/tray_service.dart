import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// 关闭按钮的落点。用户可以在弹出的对话框里"记住选择"。
enum CloseAction {
  /// 每次都问（默认，第一次用的人不会莫名其妙找不着软件）
  ask,
  /// 缩到系统托盘通知区，程序继续在后台收消息
  minimize,
  /// 真的退出
  exit,
}

/// 用户点了 × 之后的选择（含"要不要记住"）。
typedef CloseChoice = ({CloseAction action, bool remember});

/// 桌面端的「关闭 = 缩到托盘」行为。
///
/// 【为什么需要它】
/// 主流聊天软件（微信/QQ/钉钉）点右上角 ×**都不会退出**，而是缩到桌面右下角的
/// 通知区继续收消息。用户早就形成肌肉记忆了：顺手一点 ×，结果程序整个消失、
/// 消息也收不到 —— 会被当成这软件有毛病。
///
/// 【三条不能踩的线】
/// 1. **必须留一个真正的退出口**。躲在托盘里点不掉的程序是流氓软件的样子，
///    所以托盘菜单里永远有「退出」。
/// 2. **第一次必须问**。直接吞掉关闭事件会让人不知道程序去哪了。
/// 3. **来电必须能把窗口叫回来**。铃声响了窗口却缩在托盘里等于漏接，
///    所以 `showFromTray()` 会被通话引擎调用。
class TrayService with WindowListener, TrayListener {
  TrayService._();

  static final TrayService instance = TrayService._();

  static const _kAction = 'xz_close_action';

  bool _inited = false;
  bool _exiting = false;
  bool _asking = false; // 对话框已经弹出来了，别重复弹
  CloseAction _action = CloseAction.ask;

  GlobalKey<NavigatorState>? _navKey;

  /// 全局导航 key：窗口关闭前要靠它把"问一句话"的对话框弹出来。
  void attachNavigator(GlobalKey<NavigatorState> key) => _navKey = key;

  /// 只认桌面端。Android 有自己的前往/后台语义，硬套托盘反而是灾难。
  static bool get supported => Platform.isWindows || Platform.isLinux;

  /// 当前的关闭行为（设置菜单要把它显示出来并允许改回去）
  CloseAction get action => _action;

  /// 用户当前偏好（供 UI 展示）
  String get actionLabel {
    switch (_action) {
      case CloseAction.ask:
        return '每次询问';
      case CloseAction.minimize:
        return '缩到托盘';
      case CloseAction.exit:
        return '直接退出';
    }
  }

  Future<void> init() async {
    if (_inited || !supported) return;
    _inited = true;

    // 先把上次的"记住选择"读回来
    try {
      final p = await SharedPreferences.getInstance();
      final v = p.getString(_kAction);
      _action = v == 'minimize'
          ? CloseAction.minimize
          : (v == 'exit' ? CloseAction.exit : CloseAction.ask);
    } catch (_) {
      _action = CloseAction.ask;
    }

    try {
      await windowManager.ensureInitialized();
      // ⚠️ 这一句是整个功能的地基：不开这个开关，WM_CLOSE 会直接把进程带走，
      // onWindowClose 里做什么都来不及。
      await windowManager.setPreventClose(true);
      windowManager.addListener(this);
    } catch (e) {
      debugPrint('[tray] window_manager 初始化失败：$e');
      return;
    }

    try {
      // 路径是相对 `<exe目录>/data/flutter_assets` 的，见 tray_manager 的 setIcon 实现。
      // 放在 assets/ 下并在 pubspec 里声明，Release 包才找得到这个文件。
      await trayManager.setIcon('assets/tray.ico');
      await trayManager.setToolTip('小智 IM');
      await _buildMenu();
      trayManager.addListener(this);
    } catch (e) {
      debugPrint('[tray] 托盘图标初始化失败：$e（不影响主功能，只是用不了托盘）');
    }
  }

  Future<void> _buildMenu() async {
    await trayManager.setContextMenu(
      Menu(items: [
        MenuItem(key: 'show', label: '打开主窗口'),
        MenuItem.separator(),
        MenuItem(key: 'exit', label: '退出小智 IM'),
      ]),
    );
  }

  // ------------------------------------------------------------ 窗口事件

  @override
  void onWindowClose() {
    if (_exiting) return; // 已经决定要退出了，放行
    if (_action == CloseAction.minimize) {
      unawaited(minimizeToTray());
      return;
    }
    if (_action == CloseAction.exit) {
      unawaited(appExit());
      return;
    }
    if (_asking) return;
    unawaited(_ask());
  }

  @override
  void onWindowMinimize() {
    // 点最小化时也把任务栏按钮收起来，行为才和"缩到托盘"一致。
    // 不这么做会出现"任务栏有图标 + 托盘也有图标"的双份，很别扭。
    if (Platform.isWindows) unawaited(minimizeToTray());
  }

  // ------------------------------------------------------------ 托盘事件

  @override
  void onTrayIconMouseDown() => unawaited(showFromTray());

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        unawaited(showFromTray());
        break;
      case 'exit':
        unawaited(appExit());
        break;
    }
  }

  // ------------------------------------------------------------ 动作

  /// 窗口缩到托盘（程序继续在跑，消息照收）
  Future<void> minimizeToTray() async {
    if (!supported) return;
    try {
      await windowManager.hide();
    } catch (e) {
      debugPrint('[tray] 隐藏窗口失败：$e');
    }
  }

  /// 把窗口叫回来并抢到前台。来电等重要场合用。
  Future<void> showFromTray() async {
    if (!supported) return;
    try {
      if (await windowManager.isMinimized()) await windowManager.restore();
      if (!await windowManager.isVisible()) await windowManager.show();
      await windowManager.focus();
    } catch (e) {
      debugPrint('[tray] 恢复窗口失败：$e');
    }
  }

  /// 真正退出。会从托盘菜单、"关闭时选退出"两处进入。
  Future<void> appExit() async {
    if (_exiting) return;
    _exiting = true;
    try {
      await trayManager.destroy(); // 先把托盘图标摘掉
    } catch (_) {
      // 摘不掉也要往下走，不能卡在这里
    }
    try {
      await windowManager.setPreventClose(false);
      await windowManager.close();
    } catch (_) {
      // 插件调用失败时，下面还有兜底
    }
    // 兜底：万一引擎没退干净，别留下一个"点了关不掉"的进程。
    // 这是最后一道保险 —— 用户点了退出就必须真的退。
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (supported) exit(0);
  }

  // ------------------------------------------------------------ 询问对话

  /// 第一次（以及没选"记住"的每次）关闭时，让用户自己挑。
  ///
  /// 之所以不擅自决定：把软件藏起来不告诉用户，和擅自退出同样让人恼火。
  Future<void> _ask() async {
    _asking = true;
    try {
      final ctx = _navKey?.currentContext;
      if (ctx == null) {
        // 拿不到 context（极少见）就退回"缩托盘"，绝不放行退出 ——
        // 用户点 × 的意图更可能是"先收起来"，不是"杀掉它"。
        await minimizeToTray();
        return;
      }
      final r = await showDialog<CloseChoice>(
        context: ctx,
        barrierDismissible: true,
        builder: (c) => const _CloseChoiceDialog(),
      );
      // 点空白处取消 = "算了不关了"，窗口就这么留着
      if (r == null) return;
      if (r.remember) await setAction(r.action);
      if (r.action == CloseAction.exit) {
        await appExit();
      } else {
        await minimizeToTray();
      }
    } finally {
      _asking = false;
    }
  }

  /// 设置菜单里改关闭行为。**必须允许改回去** ——
  /// 用户一旦在对话框里勾了"记住选择"却再也找不到地方改，这个功能就变成了绑架。
  Future<void> setAction(CloseAction a) async {
    try {
      final p = await SharedPreferences.getInstance();
      if (a == CloseAction.ask) {
        await p.remove(_kAction);
      } else {
        await p.setString(_kAction, a == CloseAction.exit ? 'exit' : 'minimize');
      }
    } catch (_) {
      // 存不下就只是下次重启回到默认，不影响本次会话
    }
    _action = a;
  }
}

class _CloseChoiceDialog extends StatefulWidget {
  const _CloseChoiceDialog();

  @override
  State<_CloseChoiceDialog> createState() => _CloseChoiceDialogState();
}

class _CloseChoiceDialogState extends State<_CloseChoiceDialog> {
  bool _remember = true;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('关闭小智 IM'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('关了窗口之后要不要继续在后台收消息？'),
          const SizedBox(height: 10),
          Row(
            children: [
              Checkbox(
                value: _remember,
                onChanged: (v) => setState(() => _remember = v ?? true),
              ),
              const Expanded(child: Text('记住我的选择，以后不再询问')),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(null),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context)
              .pop((action: CloseAction.exit, remember: _remember)),
          child: const Text('退出程序'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context)
              .pop((action: CloseAction.minimize, remember: _remember)),
          child: const Text('缩到托盘继续收消息'),
        ),
      ],
    );
  }
}
