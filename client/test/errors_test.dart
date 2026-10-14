// 错误文案中文化的纯逻辑单测（不碰平台通道，CI 的 flutter test 直接跑）。
//
// 覆盖龙哥明确遇到的 invalid credentials，以及服务端全量扫描出来的英文错误码。
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/errors.dart';

void main() {
  group('friendlyError：服务端英文错误码 → 中文', () {
    test('龙哥遇到的 invalid credentials', () {
      expect(friendlyError('invalid credentials'), '账号或密码错误');
    });

    test('鉴权类', () {
      expect(friendlyError('unauthorized'), '登录状态已失效，请重新登录');
      expect(friendlyError('forbidden'), '没有操作权限');
      expect(friendlyError('invalid token'), '登录凭证无效，请重新登录');
      expect(friendlyError('token revoked'), '登录状态已失效，请重新登录');
      expect(friendlyError('token expired'), '登录状态已过期，请重新登录');
    });

    test('注册类', () {
      expect(friendlyError('username too short'), '账号至少需要 3 个字符');
      expect(friendlyError('username taken'), '该账号已被注册');
    });

    test('资源不存在类', () {
      expect(friendlyError('not found'), '内容不存在或已被删除');
      expect(friendlyError('user not found'), '用户不存在');
      expect(friendlyError('group not found'), '群组不存在或已解散');
      expect(friendlyError('message not found'), '消息不存在或已撤回');
      expect(friendlyError('file not found'), '文件不存在或已删除');
    });

    test('大小写 / 空白 / 包装前缀都容忍', () {
      expect(friendlyError('  Invalid Credentials  '), '账号或密码错误');
      expect(friendlyError('Exception: invalid credentials'), '账号或密码错误');
      expect(friendlyError('Error: not found'), '内容不存在或已被删除');
    });

    test('已经是中文的服务端错误原样放行', () {
      expect(friendlyError('工作模式下由管理员统一添加员工账号'), '工作模式下由管理员统一添加员工账号');
      expect(friendlyError('该消息已撤回'), '该消息已撤回');
    });

    test('未命中的英文错误保留原文 + 中文附注（不瞎翻）', () {
      final r = friendlyError('some new unknown code');
      expect(r.contains('some new unknown code'), true);
      expect(r.contains('服务端返回'), true);
    });

    test('空串有兜底', () {
      expect(friendlyError(''), '操作失败，请重试');
      expect(friendlyError('   '), '操作失败，请重试');
    });
  });

  group('friendlySystemError：系统异常英文 → 中文', () {
    test('TLS 握手失败给出可操作建议', () {
      final r = friendlySystemError(
          Exception('HandshakeException: Handshake error in client ( CERTIFICATE_VERIFY_FAILED)'));
      expect(r.contains('证书不被信任'), true);
      expect(r.contains('http://'), true); // 关键提示：内网改用 http
    });

    test('连接被拒 / 重置 / 不可达', () {
      expect(friendlySystemError(Exception('Connection refused')), contains('拒绝'));
      expect(friendlySystemError(Exception('Connection reset by peer')), contains('重置'));
      expect(friendlySystemError(Exception('Network is unreachable')), contains('网络不可达'));
    });

    test('超时', () {
      expect(friendlySystemError(Exception('TimeoutException')), contains('超时'));
    });

    test('域名解析失败', () {
      expect(friendlySystemError(Exception('Failed host lookup: xxx')), contains('连不上'));
    });
  });
}
