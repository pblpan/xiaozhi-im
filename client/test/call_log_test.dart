import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/models.dart';

/// 通话记录（kind='call'）的解析与文案。
/// 服务端每个终态都会落一条，客户端必须能容忍脏数据并给出正确文案。
void main() {
  group('CallLog 解析', () {
    test('正常 JSON 解析', () {
      final c = CallLog.tryParse(
          jsonEncode({'mode': 'video', 'status': 'ended', 'duration': 125}));
      expect(c, isNotNull);
      expect(c!.isVideo, isTrue);
      expect(c.status, 'ended');
      expect(c.duration, 125);
    });

    test('空 / 非 JSON / 非对象 一律返回 null（调用方降级渲染）', () {
      expect(CallLog.tryParse(null), isNull);
      expect(CallLog.tryParse(''), isNull);
      expect(CallLog.tryParse('   '), isNull);
      expect(CallLog.tryParse('不是 JSON'), isNull);
      expect(CallLog.tryParse('[1,2]'), isNull);
      expect(CallLog.tryParse('"字符串"'), isNull);
    });

    test('缺字段时用兜底值，不抛异常', () {
      final c = CallLog.tryParse('{}');
      expect(c, isNotNull);
      expect(c!.mode, 'audio');
      expect(c.status, 'ended');
      expect(c.duration, 0);
    });

    test('duration 为浮点 / 字符串数字也能收敛成整数秒', () {
      expect(CallLog.tryParse('{"duration": 62.7}')!.duration, 62);
      expect(CallLog.tryParse('{"duration": 8}')!.duration, 8);
    });
  });

  group('CallLog 时长文案', () {
    test('不足 1 小时用 mm:ss', () {
      expect(const CallLog(duration: 0).durationText, '00:00');
      expect(const CallLog(duration: 5).durationText, '00:05');
      expect(const CallLog(duration: 65).durationText, '01:05');
      expect(const CallLog(duration: 599).durationText, '09:59');
      expect(const CallLog(duration: 3599).durationText, '59:59');
    });

    test('超过 1 小时用 h:mm:ss', () {
      expect(const CallLog(duration: 3600).durationText, '1:00:00');
      expect(const CallLog(duration: 3725).durationText, '1:02:05');
    });

    test('负数兜底成 0', () {
      expect(const CallLog(duration: -10).durationText, '00:00');
    });
  });

  group('CallLog 展示文案', () {
    test('接通并有时长', () {
      expect(const CallLog(mode: 'video', duration: 125).label, '视频通话  02:05');
      expect(const CallLog(mode: 'audio', duration: 30).label, '语音通话  00:30');
    });

    test('接通但时长 0（瞬间挂断）不显示时长', () {
      expect(const CallLog(mode: 'video', duration: 0).label, '视频通话');
    });

    test('各异常状态文案', () {
      expect(const CallLog(mode: 'video', status: 'missed').label, '视频通话 · 未接听');
      expect(const CallLog(mode: 'audio', status: 'missed').label, '语音通话 · 未接听');
      expect(const CallLog(mode: 'video', status: 'rejected').label, '视频通话 · 已拒绝');
      expect(const CallLog(mode: 'video', status: 'canceled').label, '视频通话 · 已取消');
      expect(const CallLog(mode: 'video', status: 'busy').label, '视频通话 · 对方忙线中');
      expect(const CallLog(mode: 'video', status: 'failed').label, '视频通话 · 通话中断');
    });

    test('未知状态兜底成通话类型，不显示原始状态码', () {
      expect(const CallLog(mode: 'video', status: '??').label, '视频通话');
    });

    test('isMissed 只对非正常结束为真', () {
      expect(const CallLog(status: 'ended').isMissed, isFalse);
      for (final s in ['missed', 'rejected', 'canceled', 'busy', 'failed']) {
        expect(CallLog(status: s).isMissed, isTrue, reason: s);
      }
    });
  });

  group('Message.call 接线', () {
    test('kind=call 时能取到记录，其它类型为 null', () {
      final m = Message.fromJson({
        'id': 1,
        'conversation_id': 2,
        'sender_id': 3,
        'kind': 'call',
        'content': jsonEncode({'mode': 'audio', 'status': 'ended', 'duration': 9}),
        'created_at': 0,
      });
      expect(m.call, isNotNull);
      expect(m.call!.label, '语音通话  00:09');

      final t = Message.fromJson({
        'id': 2,
        'conversation_id': 2,
        'sender_id': 3,
        'kind': 'text',
        'content': '你好',
        'created_at': 0,
      });
      expect(t.call, isNull);
    });

    test('kind=call 但 content 是脏数据时返回 null（走降级渲染）', () {
      final m = Message.fromJson({
        'id': 3,
        'conversation_id': 2,
        'sender_id': 3,
        'kind': 'call',
        'content': 'garbage',
        'created_at': 0,
      });
      expect(m.call, isNull);
    });
  });
}
