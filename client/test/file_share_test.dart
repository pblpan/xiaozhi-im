import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/file_share.dart';

/// 「导出后把文件发出去」这条路的判定单测。
///
/// ── 为什么这四个组合必须都测 ───────────────────────────────────
/// 界面里如果直接写 `Platform.isAndroid`，测试跑在 Windows 上就**永远只走
/// 桌面分支** —— 手机那条路（现场唯一在用的那条）一次都没被验证过。
/// 所以判定逻辑抽成了纯函数 [FileShare.channelFor]，这里把四种组合过一遍。
///
/// 每条断言问一句"什么坏情况能让它失败"：
///   · 手机误判成桌面 → 现场看到"打开文件夹"，而手机上根本没有文件夹
///   · 桌面误判成手机 → 摆出一个点了没反应的"发给同事"（假按钮）
///   · 两个都不是的平台（Linux/macOS）→ 必须**没有**按钮，而不是乱给一个
void main() {
  group('channelFor 四象限', () {
    test('Android/iOS：走系统分享面板', () {
      expect(
        FileShare.channelFor(canShare: true, isWindows: false),
        ShareChannel.systemShare,
        reason: '手机上没有"我保存到哪个文件夹"这回事，必须直接弹分享面板',
      );
    });

    test('Android 上即使 isWindows 判错也不影响（两边都为真时以分享优先）', () {
      // 这是刻意的优先级：有真分享面板就永远用它。
      // 写成 `if (isWindows) ... else if (canShare) ...` 的话，一旦 isWindows
      // 因平台识别异常为 true，手机上就会退化成"打开文件夹"。
      expect(
        FileShare.channelFor(canShare: true, isWindows: true),
        ShareChannel.systemShare,
      );
    });

    test('Windows：退到"打开所在文件夹"', () {
      expect(
        FileShare.channelFor(canShare: false, isWindows: true),
        ShareChannel.openFolder,
        reason: 'Windows 没有系统分享面板，只能给文件夹出口让用户拖进微信',
      );
    });

    test('既没有分享面板也不是 Windows：不给按钮', () {
      expect(
        FileShare.channelFor(canShare: false, isWindows: false),
        ShareChannel.none,
        reason: '点了没反应比没这个按钮更糟，宁可不显示',
      );
    });
  });

  group('mimeOf 按扩展名猜类型', () {
    test('.csv / .txt 各自对上（发出去时微信按 MIME 过滤）', () {
      expect(FileShare.mimeOf('扫码_PD1.csv'), 'text/csv');
      expect(FileShare.mimeOf('扫码明细_PD1.txt'), 'text/plain');
    });

    test('大小写不敏感 + 认路径不认文件名', () {
      expect(FileShare.mimeOf(r'C:\tmp\A.CSV'), 'text/csv');
      expect(FileShare.mimeOf('/data/user/0/x/files/downloads/A.TXT'),
          'text/plain');
    });

    test('认不出来就退 */*', () {
      // 猜错的代价不是报错，而是**分享面板里少了微信/企微**，
      // 现场看到"能分享但目标 App 不在列表里"，极难排查。
      // 所以宁可多列几个 App。
      expect(FileShare.mimeOf('报表.unknown'), '*/*');
      expect(FileShare.mimeOf('没有扩展名'), '*/*');
    });
  });
}
