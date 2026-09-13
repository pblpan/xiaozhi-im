// 远程协助的数据模型单测
//
// 这两个模型是"审计记录"的全部来源 —— 事后追查"谁什么时候控过谁的电脑"
// 全靠它们。所以这里重点验证**服务端返回缺字段 / 类型不对时不崩**，
// 以及"是否过期 / 是否用过"这类会影响安全判断的派生结论。
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/remote_models.dart';

void main() {
  group('RemoteCode', () {
    test('服务端缺字段时走默认值，不崩', () {
      final c = RemoteCode.fromJson({});
      expect(c.id, 0);
      expect(c.label, '');
      expect(c.singleUse, isFalse);
      expect(c.expiresAt, isNull);
      expect(c.useCount, 0);
      expect(c.lastUsedAt, isNull);
      expect(c.createdAt, 0);
    });

    test('字段类型不对也不抛', () {
      for (final bad in <Map<String, dynamic>>[
        {'id': 'x', 'label': 42, 'singleUse': 'yes', 'useCount': '1'},
        {'singleUse': null, 'expiresAt': 'soon'},
        {'id': null, 'label': null},
      ]) {
        expect(() => RemoteCode.fromJson(bad), returnsNormally,
            reason: '输入 $bad 不应抛异常');
      }
    });

    test('长期有效的码永不过期', () {
      final c = RemoteCode.fromJson({'expiresAt': null});
      expect(c.expired, isFalse);
    });

    test('过期时间在未来 / 过去能正确区分', () {
      final now = DateTime.now().millisecondsSinceEpoch;
      expect(RemoteCode.fromJson({'expiresAt': now + 60000}).expired, isFalse);
      expect(RemoteCode.fromJson({'expiresAt': now - 1000}).expired, isTrue);
    });

    test('一次性码：没用过可用，用过就作废', () {
      expect(
        RemoteCode.fromJson({'singleUse': true, 'useCount': 0}).usedUp,
        isFalse,
      );
      expect(
        RemoteCode.fromJson({'singleUse': true, 'useCount': 1}).usedUp,
        isTrue,
      );
    });

    test('长期码不会因为被用过而失效', () {
      expect(
        RemoteCode.fromJson({'singleUse': false, 'useCount': 99}).usedUp,
        isFalse,
      );
    });

    test('明文 code 字段不该出现在模型里', () {
      // ⚠️ 这条是刻意的护栏：明文访问码只在"生成的那一刻"返回一次，
      // 之后服务端只剩哈希。万一哪天有人顺手加回来，这条会红。
      expect(RemoteCode.fromJson({'code': '123456'}).toString(),
          isNot(contains('123456')));
    });
  });

  group('RemoteSessionRecord', () {
    test('role 决定 peerName 取谁', () {
      final host = RemoteSessionRecord.fromJson({
        'role': 'host',
        'hostName': '我',
        'controllerName': '老李',
      });
      expect(host.role, RemoteRole.host);
      expect(host.peerName, '老李');

      final ctrl = RemoteSessionRecord.fromJson({
        'role': 'controller',
        'hostName': '老李',
        'controllerName': '我',
      });
      expect(ctrl.role, RemoteRole.controller);
      expect(ctrl.peerName, '老李');
    });

    test('role 缺失 / 非法时按 controller 处理（保守方向）', () {
      expect(RemoteSessionRecord.fromJson({}).role, RemoteRole.controller);
      expect(
        RemoteSessionRecord.fromJson({'role': 'whatever'}).role,
        RemoteRole.controller,
      );
    });

    test('缺字段走默认值', () {
      final s = RemoteSessionRecord.fromJson({});
      expect(s.sessionId, '');
      expect(s.mode, 'attended');
      expect(s.durationSec, 0);
      expect(s.controllerId, isNull);
      expect(s.startedAt, isNull);
      expect(s.endedAt, isNull);
      expect(s.hostDevice, '');
    });

    test('设备名缺失不影响（旧服务端不下发这两个字段）', () {
      final s = RemoteSessionRecord.fromJson({
        'sessionId': 'abc',
        'hostId': 1,
        'hostDevice': null,
        'controllerDevice': null,
      });
      expect(s.sessionId, 'abc');
      expect(s.hostDevice, '');
      expect(s.controllerDevice, '');
    });
  });

  group('结束原因文案', () {
    test('已知原因都有中文文案', () {
      final map = <String, String>{
        'host_end': '对方已断开',
        'controller_end': '你已断开连接',
        'timeout': '会话超时已自动结束',
        'rejected': '对方拒绝了协助请求',
        'canceled': '你取消了请求',
        'offline': '对方已离线',
        'failed': '连接失败',
      };
      map.forEach((k, v) {
        expect(remoteEndReasonText(k), v, reason: k);
      });
    });

    test('空原因给兜底文案', () {
      expect(remoteEndReasonText(''), '已结束');
    });

    test('未知原因原文返回，不吞信息（排查时全靠它）', () {
      expect(remoteEndReasonText('some_new_reason'), 'some_new_reason');
    });
  });
}
