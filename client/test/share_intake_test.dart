import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/share_intake.dart';

/// 「分享到小智」的入口语义测试。
///
/// `init()` 要过平台通道（Windows 上 `Platform.isAndroid` 直接 false，
/// 单测里根本进不去），所以这里是直接打 `handleRaw()` —— 它才是
/// "原生回传的原始数据 → pending / notice" 的全部逻辑。
void main() {
  setUp(() {
    // pending / notice 是静态的，测试之间会互相污染，每条前重置
    ShareIntake.pending.value = null;
    ShareIntake.notice.value = null;
  });

  Map<String, dynamic> shareWithFile({String path = '/tmp/share/a.jpg'}) => {
        'files': [
          {'path': path, 'name': 'a.jpg', 'mime': 'image/jpeg', 'size': 123}
        ],
        'text': '',
      };

  // ============================================================
  group('handleRaw：正常分享', () {
    test('有文件 → 落进 pending，且不设 notice', () {
      ShareIntake.handleRaw(shareWithFile());
      expect(ShareIntake.pending.value, isNotNull);
      expect(ShareIntake.pending.value!.files, hasLength(1));
      // 反向：成功路径不许顺手弹提示，否则每次分享都糊一条"没读到"
      expect(ShareIntake.notice.value, isNull,
          reason: '成功分享不该出现"没读到你分享的内容"');
    });

    test('只有文字也算有效分享', () {
      ShareIntake.handleRaw({'files': const [], 'text': '看这个'});
      expect(ShareIntake.pending.value, isNotNull);
      expect(ShareIntake.pending.value!.text, '看这个');
      expect(ShareIntake.notice.value, isNull);
    });
  });

  // ============================================================
  group('handleRaw：读不到内容', () {
    test('空对象 → notice 有值、pending 仍为空', () {
      ShareIntake.handleRaw({'files': const [], 'text': ''});
      expect(ShareIntake.notice.value, isNotNull);
      expect(ShareIntake.pending.value, isNull);
    });

    test('非 Map 的脏数据 → 当成空内容处理，不许崩', () {
      ShareIntake.handleRaw('not-a-map');
      expect(ShareIntake.notice.value, isNotNull);
      expect(ShareIntake.pending.value, isNull);
    });

    test('files 里全是非法项（没有 path）→ 等于空内容', () {
      ShareIntake.handleRaw({
        'files': [
          {'name': 'a.jpg'}, // 没有 path，SharedFile.fromMap 会丢掉它
        ],
        'text': '',
      });
      expect(ShareIntake.notice.value, isNotNull);
      expect(ShareIntake.pending.value, isNull);
    });

    test('🔴 上一份还没被消费，又来一次读不到内容 → pending 必须被清掉', () {
      // 这是回归测试：老写法只在 p == null 时设 notice，**不动 pending** →
      // 界面上会弹出"跟这次分享毫无关系的上一份内容"。
      ShareIntake.handleRaw(shareWithFile(path: '/tmp/share/first.jpg'));
      expect(ShareIntake.pending.value, isNotNull, reason: '前置条件：已有一份待消费');

      ShareIntake.handleRaw({'files': const [], 'text': ''});

      expect(ShareIntake.pending.value, isNull,
          reason: '留着旧 pending ⇒ 用户第二次分享会看到第一次的东西');
      expect(ShareIntake.notice.value, isNotNull);
    });
  });

  // ============================================================
  group('handleRaw：不是分享（正常点图标启动）', () {
    test('raw == null → 什么都不动', () {
      ShareIntake.handleRaw(null);
      expect(ShareIntake.pending.value, isNull);
      expect(ShareIntake.notice.value, isNull,
          reason: '正常启动弹"没读到你分享的内容"会让人莫名其妙');
    });

    test('raw == null 不会抹掉已有的 pending', () {
      ShareIntake.handleRaw(shareWithFile());
      final before = ShareIntake.pending.value;
      ShareIntake.handleRaw(null);
      expect(identical(ShareIntake.pending.value, before), isTrue);
    });
  });

  // ============================================================
  group('consume / SharedPayload.from', () {
    test('consume() 之后 pending 为空（返回时不再弹一次）', () {
      ShareIntake.handleRaw(shareWithFile());
      ShareIntake.consume();
      expect(ShareIntake.pending.value, isNull);
    });

    test('from：全空返回 null，有内容才给对象', () {
      expect(SharedPayload.from({'files': const [], 'text': ''}), isNull);
      expect(SharedPayload.from(null), isNull);
      expect(SharedPayload.from(123), isNull);
      expect(SharedPayload.from(shareWithFile()), isNotNull);
    });

    test('isImage 三处都认：服务端 mime / 原始名 / 落地名', () {
      // 有 App 分享时不带 mime，只能靠文件名认
      final byMime = SharedPayload.from({
        'files': [
          {'path': '/tmp/share/x.bin', 'name': 'x.bin', 'mime': 'image/png'}
        ]
      })!;
      expect(byMime.files.first.isImage, isTrue);

      final byName = SharedPayload.from({
        'files': [
          {'path': '/tmp/share/x.bin', 'name': 'x.JPG', 'mime': ''}
        ]
      })!;
      expect(byName.files.first.isImage, isTrue);

      final notImage = SharedPayload.from({
        'files': [
          {'path': '/tmp/share/x.pdf', 'name': 'x.pdf', 'mime': 'application/pdf'}
        ]
      })!;
      expect(notImage.files.first.isImage, isFalse);
    });

    test('totalBytes 累加各附件', () {
      final p = SharedPayload.from({
        'files': [
          {'path': '/tmp/share/a.jpg', 'name': 'a.jpg', 'size': 100},
          {'path': '/tmp/share/b.jpg', 'name': 'b.jpg', 'size': 250},
        ]
      })!;
      expect(p.totalBytes, 350);
    });
  });
}
