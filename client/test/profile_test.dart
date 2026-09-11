import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/models.dart';

/// 个人资料 / 好友申请 / 认证模板 的模型解析测试。
///
/// 这些字段全部是「可空」的：老用户没填过、服务端返回 null 很常见。
/// 一旦 fromJson 写成 `m['x'] as String`，老用户一登录就崩 —— 所以必须测。
void main() {
  group('User 资料字段', () {
    test('完整资料解析', () {
      final u = User.fromJson({
        'id': 7,
        'username': 'alice',
        'nickname': '爱丽丝',
        'avatar': '/files/a.png',
        'role': 'user',
        'signature': '今天也要好好吃饭',
        'gender': 'female',
        'region': '黑龙江 海伦',
        'birthday': '2000-02-29',
      });
      expect(u.id, 7);
      expect(u.display, '爱丽丝');
      expect(u.signature, '今天也要好好吃饭');
      expect(u.genderLabel, '女');
      expect(u.region, '黑龙江 海伦');
      expect(u.birthday, '2000-02-29');
    });

    test('老用户（资料字段全缺）不崩，且各字段为 null', () {
      final u = User.fromJson({'id': 1, 'username': 'bob'});
      expect(u.nickname, isNull);
      expect(u.signature, isNull);
      expect(u.gender, isNull);
      expect(u.region, isNull);
      expect(u.birthday, isNull);
      expect(u.genderLabel, isNull);
      // 没昵称时显示账号
      expect(u.display, 'bob');
    });

    test('昵称为空串时回落到账号', () {
      final u = User.fromJson({'id': 2, 'username': 'carol', 'nickname': ''});
      expect(u.display, 'carol');
    });

    test('性别文案映射', () {
      String? label(String? g) =>
          User.fromJson({'id': 1, 'username': 'x', 'gender': g}).genderLabel;
      expect(label('male'), '男');
      expect(label('female'), '女');
      expect(label('other'), '保密');
      expect(label(''), isNull);
      expect(label(null), isNull);
      // 服务端将来加了新枚举，客户端不认识也不能崩，显示成「未设置」
      expect(label('unknown'), isNull);
    });
  });

  group('FriendRequest 好友申请', () {
    test('带附言的申请解析', () {
      final r = FriendRequest.fromJson({
        'id': 9,
        'username': 'dave',
        'nickname': '大卫',
        'avatar': '/files/d.png',
        'signature': '你好',
        'message': '我是隔壁老王介绍的',
        'created_at': 1789000000000,
      });
      expect(r.userId, 9);
      expect(r.display, '大卫');
      expect(r.message, '我是隔壁老王介绍的');
      expect(r.createdAt, 1789000000000);
      expect(r.asUser.id, 9);
      expect(r.asUser.display, '大卫');
    });

    test('没有附言 / 字段缺失时不崩', () {
      final r = FriendRequest.fromJson({'id': 3, 'username': 'eve'});
      expect(r.message, '');
      expect(r.createdAt, 0);
      expect(r.display, 'eve');
      expect(r.avatar, isNull);
    });

    test('附言是 null 时归一化为空串', () {
      final r = FriendRequest.fromJson({'id': 4, 'username': 'f', 'message': null});
      expect(r.message, '');
    });
  });

  group('FriendTemplate 认证模板', () {
    test('解析 id 与内容', () {
      final t = FriendTemplate.fromJson({'id': 12, 'content': '我们在群里聊过'});
      expect(t.id, 12);
      expect(t.content, '我们在群里聊过');
    });

    test('内容缺失时为空串（渲染成空 chip 不好看，交由上层判空）', () {
      final t = FriendTemplate.fromJson({'id': 13});
      expect(t.content, '');
    });
  });
}
