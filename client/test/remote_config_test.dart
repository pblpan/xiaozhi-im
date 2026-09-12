// RemoteConfig 纯逻辑单测（SPEC-动态配置与模块.md 第一期）
//
// 网络部分无法在本测试里验证（那是 e2e 的事），这里覆盖的是
// 绝对不能错的纯函数：版本比较、地址候选的语义。
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/remote_config.dart';

void main() {
  group('versionLess（语义化版本比较）', () {
    test('正常比较', () {
      expect(RemoteConfig.versionLess('0.7.0', '0.8.0'), isTrue);
      expect(RemoteConfig.versionLess('0.8.0', '0.7.0'), isFalse);
      expect(RemoteConfig.versionLess('0.7.0', '0.7.0'), isFalse);
      expect(RemoteConfig.versionLess('0.7.1', '0.7.0'), isFalse);
      expect(RemoteConfig.versionLess('1.0.0', '0.9.9'), isFalse);
    });

    test('位数不同按补零对齐', () {
      expect(RemoteConfig.versionLess('0.7', '0.7.1'), isTrue);
      expect(RemoteConfig.versionLess('0.7.0', '0.7'), isFalse);
      expect(RemoteConfig.versionLess('1.0', '1.0.0'), isFalse);
    });

    test('非数字段按 0 处理（不抛异常）', () {
      expect(RemoteConfig.versionLess('a.b', '0.0.1'), isTrue);
      expect(RemoteConfig.versionLess('', ''), isFalse);
    });
  });
}
