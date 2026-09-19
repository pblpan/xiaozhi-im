import 'dart:io';

import 'package:flutter/material.dart';

import '../core/file_io.dart';
import '../core/file_share.dart';
import '../core/theme.dart';

/// 导出完之后的那一套弹层与动作（发给同事 / 打开 / 另存为）。
///
/// ── 从 IM 客户端切出来时砍掉了什么 ────────────────────────────
/// 原文件有一条 Windows 专属分支："打开所在文件夹，让用户拖进微信"
/// （依赖 `WinShell.revealInExplorer`）。独立扫码枪只出 Android 包，
/// 那条分支在这台设备上永远走不到 —— 留在界面上就是**点了没反应的假按钮**，
/// 所以整段删掉：这里只留 Android 真能走的三条路。
///
/// ── 一条平台铁律（保留）──────────────────────────────────────
/// **第一优先永远是"直接发给同事"**。导出的目的就是发出去；
/// 先落盘再让用户自己去文件管理器找回来发，中间那两步纯属白干。
/// 手机上有系统分享面板（微信/企微/钉钉都在里面），这条路是真东西。
class ExportFlow {
  ExportFlow._();

  /// 弹出导出后的操作面板。[rows] 只用于提示文案。
  ///
  /// [suggestName] 是"另存为"时的建议文件名 —— 用**调用方期望的名字**，
  /// 而不是从临时路径里猜（临时文件名可能带随机后缀）。
  static Future<void> show(
    BuildContext context,
    File f, {
    required int rows,
    required String suggestName,
    void Function(String msg)? onMessage,
  }) async {
    final act = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.bgElevated,
      builder: (ctx) => SafeArea(
        // 弹层里最多 4 条，小屏 + 系统大字体下会超出底部弹层的最大高度，
        // 最后一条（"先不用"）会落在屏幕外**点不到**。给个滚动兜底。
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.check_circle_outline,
                    color: AppColors.brand),
                title: Text('已生成 $rows 行：${fileNameOf(f)}',
                    style: const TextStyle(color: AppColors.text, fontSize: 13)),
              ),
              ListTile(
                key: const Key('share-to-others'),
                leading: const Icon(Icons.send, color: AppColors.brand),
                title: const Text('发给同事（微信 / 企微 / 钉钉…）',
                    style: TextStyle(
                        color: AppColors.text, fontWeight: FontWeight.w600)),
                onTap: () => Navigator.pop(ctx, 'share'),
              ),
              ListTile(
                leading: const Icon(Icons.open_in_new, color: AppColors.textSub),
                title: const Text('打开（用 WPS / Excel / 记事本看）',
                    style: TextStyle(color: AppColors.text)),
                onTap: () => Navigator.pop(ctx, 'open'),
              ),
              ListTile(
                leading: const Icon(Icons.save_alt, color: AppColors.textSub),
                title: const Text('另存为 / 发到别处',
                    style: TextStyle(color: AppColors.text)),
                onTap: () => Navigator.pop(ctx, 'save'),
              ),
              ListTile(
                leading: const Icon(Icons.close, color: AppColors.textWeak),
                title:
                    const Text('先不用', style: TextStyle(color: AppColors.textSub)),
                onTap: () => Navigator.pop(ctx),
              ),
            ],
          ),
        ),
      ),
    );
    if (act == null) return;
    if (!context.mounted) return;

    if (act == 'share') {
      // 分享面板是系统的，拉起来就完事 —— 用户选谁发是他自己的事，
      // 我们拿不到"发没发成功"的回执（Android 不给），所以这里只说"已打开"。
      //
      // 标题取**实际文件名**，不是拿单号现拼一个：导出文档(.txt) 与
      // 导出表格(.csv) 是两个文件，标题写错会让接收方以为拿到的不是这份。
      final err = await FileShare.toOthers(f, subject: fileNameOf(f));
      onMessage?.call(err.isEmpty ? '已打开分享面板，选同事发送即可' : err);
      return;
    }
    if (act == 'open') {
      final err = await FileIo.open(f);
      onMessage?.call(err.isEmpty ? '已交给系统打开' : err);
      return;
    }
    final where = await FileIo.saveAs(f, suggestName);
    onMessage?.call(where == null ? '已取消' : '已保存：$where');
  }

  /// 文件的实际名字（含扩展名）。分享标题、提示文案都用它，
  /// 不去拿单号现拼 —— 拼出来的名字和真实文件可能不是一份。
  static String fileNameOf(File f) => f.path.split(Platform.pathSeparator).last;

  /// 是不是文本文档（决定"另存为"时用哪个名字）。
  static bool asDocName(File f) => f.path.toLowerCase().endsWith('.txt');
}
