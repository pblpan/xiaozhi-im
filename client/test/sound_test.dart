import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';

/// 提示音资源的存在性与格式校验。
///
/// 这类测试的价值在于：音频是二进制资源，漏配 pubspec 的 assets 段时
/// 编译期毫无反应，只有真机收消息那一刻才会「静音」——很难排查。
int _u32(Uint8List b, int off) =>
    b[off] | (b[off + 1] << 8) | (b[off + 2] << 16) | (b[off + 3] << 24);

void main() {
  // rootBundle 读资源依赖 ServicesBinding，测试里必须显式初始化
  TestWidgetsFlutterBinding.ensureInitialized();

  const files = {
    'assets/sounds/message.wav': (0.1, 0.5), // 消息音：0.1~0.5 秒
    'assets/sounds/ringtone.wav': (1.0, 4.0), // 来电铃声：1~4 秒（循环播放）
    'assets/sounds/outgoing.wav': (1.0, 4.0), // 呼出回铃：1~4 秒（循环播放）
  };

  for (final entry in files.entries) {
    test('音频资源 ${entry.key} 存在且是合法 WAV', () async {
      final data = await rootBundle.load(entry.key);
      final b = data.buffer.asUint8List();

      // RIFF....WAVE 头
      expect(String.fromCharCodes(b.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(b.sublist(8, 12)), 'WAVE');

      // 用 fmt 块的字节率反推时长，确认不是空文件/截断文件
      final byteRate = _u32(b, 28);
      expect(byteRate, greaterThan(0));
      final seconds = (b.length - 44) / byteRate;
      final (min, max) = entry.value;
      expect(seconds, greaterThan(min), reason: '${entry.key} 时长过短，可能生成失败');
      expect(seconds, lessThan(max), reason: '${entry.key} 时长过长');
    });
  }
}
