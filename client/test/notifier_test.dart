import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/notifier.dart';
import 'package:xiaozhi_im_client/models.dart';

/// 通知的判定逻辑测试。
///
/// 只打纯函数（shouldNotify / previewOf）—— 那才是"什么时候弹、弹什么"
/// 的全部决策；真正发通知要走平台通道，单测环境里没有原生实现
/// （与 share_intake_test.dart 同一思路：测逻辑，不测通道）。
Message _msg({
  int id = 1,
  int conversationId = 10,
  int senderId = 99,
  String kind = 'text',
  String? content = '你好',
  String? fileName,
  bool deleted = false,
}) =>
    Message(
      id: id,
      conversationId: conversationId,
      senderId: senderId,
      kind: kind,
      content: content,
      fileName: fileName,
      createdAt: 1700000000,
      deleted: deleted,
    );

void main() {
  group('shouldNotify：该不该弹这条通知', () {
    test('别人发的新消息 → 弹', () {
      expect(
        MessageNotifier.shouldNotify(
          fromMe: false,
          deleted: false,
          muted: false,
          foreground: false,
          openConversationId: null,
          conversationId: 10,
        ),
        isTrue,
      );
    });

    test('自己发的（含自己其他设备）→ 不弹', () {
      expect(
        MessageNotifier.shouldNotify(
          fromMe: true,
          deleted: false,
          muted: false,
          foreground: false,
          openConversationId: null,
          conversationId: 10,
        ),
        isFalse,
      );
    });

    test('已撤回的消息 → 不弹', () {
      expect(
        MessageNotifier.shouldNotify(
          fromMe: false,
          deleted: true,
          muted: false,
          foreground: false,
          openConversationId: null,
          conversationId: 10,
        ),
        isFalse,
      );
    });

    test('免打扰会话 → 不弹（用户明确说了不想被打扰）', () {
      expect(
        MessageNotifier.shouldNotify(
          fromMe: false,
          deleted: false,
          muted: true,
          foreground: false,
          openConversationId: null,
          conversationId: 10,
        ),
        isFalse,
      );
    });

    test('前台 + 正在看这条会话 → 不弹（弹了纯打扰）', () {
      expect(
        MessageNotifier.shouldNotify(
          fromMe: false,
          deleted: false,
          muted: false,
          foreground: true,
          openConversationId: 10,
          conversationId: 10,
        ),
        isFalse,
      );
    });

    test('前台但在看**别的**会话 → 照弹', () {
      expect(
        MessageNotifier.shouldNotify(
          fromMe: false,
          deleted: false,
          muted: false,
          foreground: true,
          openConversationId: 11,
          conversationId: 10,
        ),
        isTrue,
      );
    });

    test('后台 + 哪怕正开着这条会话的页面 → 也弹', () {
      // 典型：用户在聊天页里按了 Home 键。页面还活着，但人已经走了，
      // 这时候来消息必须提醒 —— 否则就是龙哥报的"后台没提示"。
      expect(
        MessageNotifier.shouldNotify(
          fromMe: false,
          deleted: false,
          muted: false,
          foreground: false,
          openConversationId: 10,
          conversationId: 10,
        ),
        isTrue,
      );
    });
  });

  group('previewOf：通知正文文案', () {
    test('文字 → 原文', () {
      expect(MessageNotifier.previewOf(_msg(content: '  大家好  ')), '大家好');
    });
    test('图片 → [图片]', () {
      expect(MessageNotifier.previewOf(_msg(kind: 'image')), '[图片]');
    });
    test('语音 → [语音]', () {
      expect(MessageNotifier.previewOf(_msg(kind: 'audio')), '[语音]');
    });
    test('文件 → [文件] 加文件名', () {
      expect(
        MessageNotifier.previewOf(
            _msg(kind: 'file', content: null, fileName: '报表.xlsx')),
        '[文件] 报表.xlsx',
      );
    });
    test('文件但没有文件名 → 只要 [文件]', () {
      expect(
        MessageNotifier.previewOf(_msg(kind: 'file', content: null)), '[文件]');
    });
    test('名片 → [名片]', () {
      expect(MessageNotifier.previewOf(_msg(kind: 'card')), '[名片]');
    });
    test('表情 → [表情]', () {
      expect(MessageNotifier.previewOf(_msg(kind: 'emoji')), '[表情]');
    });
    test('文字为空 → 空串（调用方会兜底成"新消息"）', () {
      expect(MessageNotifier.previewOf(_msg(content: '   ')), '');
    });
  });
}
