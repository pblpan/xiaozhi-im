import 'dart:io';

import 'package:flutter/material.dart';

import '../core/file_io.dart';
import '../core/file_share.dart';
import '../core/theme.dart';
import '../core/win_shell.dart';

/// 导出完之后的那一套弹层与动作（打开 / 发给同事 / 另存为）。
///
/// ── 为什么抽成公共组件 ────────────────────────────────────────
/// 扫码枪和盘点两个模块导出后要做的事**一模一样**：
/// 都要能直接把文件发出去（这才是导出的目的）、都能打开看、都能另存。
/// 各写一份的话，下次修"某个平台少了微信"这种问题只改一处，
/// 另一处就成了"看起来有、点了没反应"的坑。
///
/// ── 一条平台铁律 ──────────────────────────────────────────────
/// **第一优先永远是"直接发给同事"**。导出的目的就是发出去；
/// 先落盘再让用户自己去文件管理器找回来发，中间那两步纯属白干。
/// 但桌面端没有系统分享面板（那是 UWP 那套，桌面应用拿不到），
/// 所以走 [FileShare.channelFor] 判定：桌面换成"打开所在文件夹"，
/// 让他把文件拖进微信 —— 决不在桌面上摆一个点了没反应的假按钮。
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
    final channel = FileShare.channel;
    final act = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.bgElevated,
      builder: (ctx) => SafeArea(
        // 弹层里最多 5 条，小屏 + 系统大字体下会超出底部弹层的最大高度，
        // 最后一条（"先不用"）会落在屏幕外**点不到**。给个滚动兜底。
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading:  Icon(Icons.check_circle_outline,
                    color: AppColors.brand),
                title: Text('已生成 $rows 行：${fileNameOf(f)}',
                    style: TextStyle(color: AppColors.text, fontSize: 13)),
              ),
              // 只给这台设备真能走的那一条 —— 见 FileShare.channelFor 的说明：
              // 在桌面上摆一个"发给同事"就是假按钮（点了没反应）。
              if (channel == ShareChannel.systemShare)
                ListTile(
                  key: const Key('share-to-others'),
                  leading: Icon(Icons.send, color: AppColors.brand),
                  title:  Text('发给同事（微信 / 企微 / 钉钉…）',
                      style: TextStyle(
                          color: AppColors.text, fontWeight: FontWeight.w600)),
                  onTap: () => Navigator.pop(ctx, 'share'),
                )
              else if (channel == ShareChannel.openFolder)
                ListTile(
                  key: const Key('share-to-others'),
                  leading: Icon(Icons.folder_open, color: AppColors.brand),
                  title:  Text('打开所在文件夹（拖进微信发送）',
                      style: TextStyle(
                          color: AppColors.text, fontWeight: FontWeight.w600)),
                  onTap: () => Navigator.pop(ctx, 'folder'),
                ),
              ListTile(
                leading: Icon(Icons.open_in_new, color: AppColors.textSub),
                title:  Text('打开（用 WPS / Excel / 记事本看）',
                    style: TextStyle(color: AppColors.text)),
                onTap: () => Navigator.pop(ctx, 'open'),
              ),
              ListTile(
                leading: Icon(Icons.save_alt, color: AppColors.textSub),
                title:  Text('另存为 / 发到别处',
                    style: TextStyle(color: AppColors.text)),
                onTap: () => Navigator.pop(ctx, 'save'),
              ),
              ListTile(
                leading: Icon(Icons.close, color: AppColors.textWeak),
                title:
                    Text('先不用', style: TextStyle(color: AppColors.textSub)),
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
    if (act == 'folder') {
      final ok = WinShell.revealInExplorer(f.path);
      onMessage?.call(ok ? '已在资源管理器中定位到该文件' : '打开文件夹失败：${f.path}');
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
