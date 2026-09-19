import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/scan_feedback.dart';

/// 扫码反馈的**纯逻辑**部分。
///
/// 播放本身（AudioPlayer + 平台通道）在测试机上起不来，也不该在这里测；
/// 但"什么时候响哪个音"这个映射**必须测**：
/// 反了的话不崩、不报错，只会让员工把"没记上"当成"记上了"——
/// 而现场是听见了就扫下一件，根本不会回头核对。
void main() {
  group('scanToneFor', () {
    test('记上了 → 成功音', () {
      expect(scanToneFor(accepted: true), ScanTone.ok);
    });

    test('🔴 没记上 → 失败音（不能也响成功音）', () {
      expect(scanToneFor(accepted: false), ScanTone.fail,
          reason: '被拒绝的扫码还响成功音 = 训练出"响了就是进去了"的错觉');
    });

    test('两个音必须不同 —— 否则现场分不出来', () {
      expect(scanToneFor(accepted: true),
          isNot(scanToneFor(accepted: false)));
    });
  });
}
