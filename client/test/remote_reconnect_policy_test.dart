// 重连策略的回归护栏 —— 对应龙哥 2026-10-25 真机故障：
//   「还是一片漆黑，但是断开连接的时候显示画面了，
//     然后再连接就没有反应，点连接按钮一点反应都没有。」
//
// 【故障链（已在真机上用截图像素分析证实）】
//   ① 被控端（offer 方）网络抖一下 → onConnectionState(Disconnected)
//   ② 控制端（answer 方）**也**去 restartIce()+createOffer()，
//      和被控端的重连 offer 撞车：双方同时 setRemoteDescription(offer)，
//      WebRTC 栈两边都报 "wrong state" 然后被 catch 吞掉
//      → 连接永远恢复不过来，手机上显示"已发送重连 offer（第 2 次）"后卡死
//   ③ 被控端退避满 5 次放弃 → _teardown 把 PC 关了 → 控制端 frames 通道
//      变成 RTCDataChannelClosed，画面停在最后一帧
//   ④ 重连浮层是一整块 Colors.black54 + 一张居中大白卡，
//      把本来就只占屏幕中间一条的 16:9 画面压暗又盖住 → 用户看到"一片漆黑"
//   ⑤ 断开连接时浮层消失，画面"唰"地亮起来 → "断开连接的时候显示画面了"
//   ⑥ 控制端 _pc 留着一条死连接，下次 redeem() 复用它去 setRemoteDescription
//      必失败 → "点连接按钮一点反应都没有"
//
// 【为什么用源码护栏而不是单测】
//   上面每一步的现场表现都是"没有报错、没有崩溃、计数照涨"，
//   靠行为单测复现不了（要真造一次 ICE 撞车）。而这些是**结构性不变量**：
//   控制端不许发 offer、重连提示不许盖画面、开新会话必须清死连接。
//   用"先剥注释再判"的源码断言钉住，比注释里写一百遍都管用。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 剥掉 Dart 源码里的注释，**保留字符串字面量**。
///
/// 为什么不能直接 `replaceAll('//...')`：remote_assist.dart 里有
/// `'https://…'` 这类 URL，一把撸会把字符串劈成两半，后面的断言就假阳性。
/// 所以按字符走，遇到引号整段跳过（含转义与三引号）。
String stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  final n = src.length;
  while (i < n) {
    final c = src[i];
    // 行注释
    if (c == '/' && i + 1 < n && src[i + 1] == '/') {
      while (i < n && src[i] != '\n') {
        i++;
      }
      continue;
    }
    // 块注释
    if (c == '/' && i + 1 < n && src[i + 1] == '*') {
      i += 2;
      while (i + 1 < n && !(src[i] == '*' && src[i + 1] == '/')) {
        i++;
      }
      i = (i + 1 < n) ? i + 2 : n;
      continue;
    }
    // 字符串：'…' "…" '''…''' """…"""（r 前缀不转义）
    if (c == '"' || c == "'") {
      final q = c;
      final triple = i + 2 < n && src[i + 1] == q && src[i + 2] == q;
      if (triple) {
        i += 3;
        while (i + 2 < n && !(src[i] == q && src[i + 1] == q && src[i + 2] == q)) {
          i++;
        }
        i = (i + 2 < n) ? i + 3 : n;
      } else {
        i++;
        while (i < n && src[i] != q) {
          if (src[i] == r'\') i++;
          i++;
        }
        i = (i < n) ? i + 1 : n;
      }
      out.write(q);
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

/// 取出某个方法体：从 `sig` 第一次出现起，到大括号配平结束。
String bodyOf(String src, String sig) {
  final start = src.indexOf(sig);
  expect(start, greaterThan(-1), reason: '找不到 $sig —— 方法被改名了？');
  var depth = 0;
  var i = src.indexOf('{', start);
  var begun = false;
  for (; i < src.length; i++) {
    if (src[i] == '{') {
      depth++;
      begun = true;
    } else if (src[i] == '}') {
      depth--;
      if (begun && depth == 0) return src.substring(start, i + 1);
    }
  }
  fail('$sig 的花括号没配平');
}

void main() {
  // 只剥一次，后面所有断言都跑在同一份"无注释"源码上。
  // ⚠️ 必须在 setUpAll 里读：expect() 在测试区外调用会抛 OutsideTestException。
  late final String assist;
  late final String screen;

  setUpAll(() {
    String read(String rel) {
      // flutter test 的工作目录是 client/；兜底再试仓库根，两种跑法都能过
      for (final base in const ['lib', '../client/lib']) {
        final f = File('$base/$rel');
        if (f.existsSync()) return f.readAsStringSync();
      }
      fail('读不到 $rel（试过 lib/ 与 ../client/lib/）');
    }

    assist = stripComments(read('core/remote_assist.dart'));
    screen = stripComments(read('screens/remote.dart'));
  });

  group('🔴 控制端绝不发起 ICE 重启（撞车根因）', () {
    test('_scheduleReconnect 必须以 isHost 为前提', () {
      final body = bodyOf(assist, 'void _scheduleReconnect()');
      // 必须有 isHost 判断，而且出现在 _reconnectTick() 之前
      // （先拦下来，才轮不到发 offer 那段）
      final guard = body.indexOf('isHost');
      final tick = body.indexOf('_reconnectTick()');
      expect(guard, greaterThan(-1),
          reason: '控制端也会走重连循环 → 双方同时 createOffer 撞车');
      expect(guard, lessThan(tick),
          reason: 'isHost 判断必须挡在 _reconnectTick() 前面');
    });

    test('_restartIce（会 createOffer）只可能被被控端链路调到', () {
      // 只数**调用**（await _restartIce()），不数方法定义本身。
      // _restartIce 的调用点只允许出现在 _reconnectTick 里，
      // 且 _reconnectTick 只可能被 isHost 分支调到（上一条已钉住）。
      final calls = RegExp(r'await\s+_restartIce\s*\(').allMatches(assist);
      expect(calls.length, 1,
          reason: '出现多处调用 → 一定有条路绕过了 isHost 闸门');
    });

    test('_onConnStateChanged 也带 isHost（WS 重连那条路）', () {
      final body = bodyOf(assist, 'void _onConnStateChanged()');
      expect(body, contains('isHost'));
    });
  });

  group('🔴 重连提示不许盖/压暗画面（"一片漆黑"直接原因）', () {
    test('重连分支里不许出现 Colors.black54', () {
      // 抓住 build 里那段 `valueListenable: _svc.reconnecting`
      final idx = screen.indexOf('valueListenable: _svc.reconnecting');
      expect(idx, greaterThan(-1));
      final seg = screen.substring(idx, idx + 400);
      expect(seg, isNot(contains('black54')),
          reason: '又用整屏半透明黑把画面压暗了');
    });

    test('重连提示不许用 Positioned.fill（不能铺满）', () {
      final idx = screen.indexOf('valueListenable: _svc.reconnecting');
      final seg = screen.substring(idx, idx + 400);
      expect(seg, isNot(contains('Positioned.fill')),
          reason: '铺满=盖住画面，龙哥 2026-10-25 正是这个');
    });

    test('横幅自身是贴顶的小条：源码里带 top: 定位', () {
      expect(screen, contains('class _ReconnectBanner'));
      // Positioned(left/right/top) 而不是 fill
      expect(screen, contains('top: 10'));
    });
  });

  group('🔴 开新会话必须先清掉上一场的死连接（"点连接没反应"）', () {
    test('redeem() 必须调 _resetForNewSession()', () {
      final body = bodyOf(assist, 'Future<String?> redeem(String code)');
      expect(body, contains('_resetForNewSession()'),
          reason: '不复位就会复用上一场的死 _pc → setRemoteDescription 必失败');
    });

    test('requestFrom() 同样要调 _resetForNewSession()', () {
      final body = bodyOf(assist, 'Future<String?> requestFrom(int hostId)');
      expect(body, contains('_resetForNewSession()'));
    });

    test('_resetForNewSession 必须把 _pc 置空并 close', () {
      final body = bodyOf(assist, 'Future<void> _resetForNewSession()');
      expect(body, contains('_pc = null'));
      expect(body, contains('pc.close()'));
      // 相位必须回到 idle，否则 redeem() 里那句
      // `if (phase == idle || ended) phase = requesting` 不会生效
      expect(body, contains('RemotePhase.idle'));
    });

    test('_resetForNewSession 不许给对端发 remote:end（对端可能早走了）', () {
      final body = bodyOf(assist, 'Future<void> _resetForNewSession()');
      expect(body, isNot(contains("'remote:end'")));
    });
  });

  group('🔴 对端关连接时控制端要跟着收摊', () {
    test('RTCPeerConnectionStateClosed 分支必须调 _teardown', () {
      final idx = assist.indexOf('RTCPeerConnectionStateClosed');
      expect(idx, greaterThan(-1));
      final seg = assist.substring(idx, idx + 700);
      expect(seg, contains('_teardown'),
          reason: '不收摊 → _pc 留着死连接 → 下次连接没反应');
    });
  });
}
