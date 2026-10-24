// 远程协助：窗口模式协议（参考 TwinDesk「Apps 面板」）
//
// 【测什么、为什么】
// 窗口模式的全部报文都走控制 DataChannel，而通道里流过来的是**对方能送上来的
// 任意字符串**。这一层解析写蹦的表象：被控端 App 崩溃（controller→host 方向），
// 或控制端 UI 拿到畸形数据白屏（host→controller 方向）。所以重点是
// "怎么喂都不抛、不认的报文一律丢弃"，正常路径只做基本断言。
//
// 这里**不碰 FFI**：窗口枚举/采集/注入都在被控端 Windows 本机发生，
// 其真机验证走手动用例（见文件末尾的 Windows 专属 smoke 组）。
import 'dart:io' show Platform;

import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/remote_assist.dart';
import 'package:xiaozhi_im_client/core/win_window_list.dart';

void main() {
  // ---------------------------------------------------------------- 解析：controller→host

  group('窗口指令解析（wl / ws / we）', () {
    test('wl 请求列表', () {
      expect(parseRemoteInput('{"v":1,"t":"wl"}'), isA<WindowListRequestAction>());
    });

    test('ws 带合法 hwnd', () {
      final a = parseRemoteInput('{"v":1,"t":"ws","hwnd":123456}')!
          as WindowSelectAction;
      expect(a.hwnd, 123456);
    });

    test('we 退出窗口模式', () {
      expect(parseRemoteInput('{"v":1,"t":"we"}'), isA<WindowExitAction>());
    });

    test('hwnd 缺失 / 非正 / 非数字一律丢弃（句柄是地址值，0 表示"没有"）', () {
      expect(parseRemoteInput('{"v":1,"t":"ws"}'), isNull);
      expect(parseRemoteInput('{"v":1,"t":"ws","hwnd":0}'), isNull);
      expect(parseRemoteInput('{"v":1,"t":"ws","hwnd":-5}'), isNull);
      expect(parseRemoteInput('{"v":1,"t":"ws","hwnd":"123"}'), isNull);
      expect(parseRemoteInput('{"v":1,"t":"ws","hwnd":null}'), isNull);
    });

    test('hwnd 是小数时截断取整（JSON 数字统一按 num 收）', () {
      final a = parseRemoteInput('{"v":1,"t":"ws","hwnd":12.9}')!
          as WindowSelectAction;
      expect(a.hwnd, 12);
    });

    test('老报文不受影响：wl/ws/we 之外的未知类型仍返回 null', () {
      expect(parseRemoteInput('{"v":1,"t":"window"}'), isNull);
    });

    test('fa 画面回执：0 也认（"确实一帧没收到"必须能报上来）', () {
      final a0 = parseRemoteInput('{"v":1,"t":"fa","n":0}')! as FrameAckAction;
      expect(a0.framesIn, 0);
      final a = parseRemoteInput('{"v":1,"t":"fa","n":321}')! as FrameAckAction;
      expect(a.framesIn, 321);
      // 缺 n / 负数一律丢（回执不能带出负帧数把诊断条格式化坏）
      expect(parseRemoteInput('{"v":1,"t":"fa"}'), isNull);
      expect(parseRemoteInput('{"v":1,"t":"fa","n":-1}'), isNull);
    });
  });

  // ---------------------------------------------------------------- 解析：host→controller

  group('窗口回报解析（wn / wsok / wg / wst）', () {
    test('wn 成功：列表逐条解析', () {
      final m = parseWindowHostMessage('''
{"v":1,"t":"wn","ok":true,"win":[
  {"hwnd":100,"title":"记事本","process":"notepad.exe","left":0,"top":0,"width":800,"height":600,"min":false},
  {"hwnd":200,"title":"计算器","process":"","left":10,"top":20,"width":300,"height":400,"min":true}
]}
''')! as WindowListMessage;
      expect(m.ok, isTrue);
      expect(m.windows.length, 2);
      expect(m.windows[0].title, '记事本');
      expect(m.windows[0].process, 'notepad.exe');
      expect(m.windows[0].subtitle, 'notepad.exe · 800x600');
      expect(m.windows[1].minimized, isTrue);
      expect(m.windows[1].subtitle, '未知进程 · 已最小化');
    });

    test('wn 失败：带原因，列表为空', () {
      final m = parseWindowHostMessage(
              '{"v":1,"t":"wn","ok":false,"why":"被控端不是 Windows 电脑"}')
          as WindowListMessage;
      expect(m.ok, isFalse);
      expect(m.why, '被控端不是 Windows 电脑');
      expect(m.windows, isEmpty);
    });

    test('wn 缺 why 时给默认原因（UI 不能显示空白）', () {
      final m = parseWindowHostMessage('{"v":1,"t":"wn","ok":false}')
          as WindowListMessage;
      expect(m.why, isNotEmpty);
    });

    test('wn 的 win 不是数组时按失败处理，不抛', () {
      final m = parseWindowHostMessage('{"v":1,"t":"wn","ok":true,"win":"x"}')
          as WindowListMessage;
      expect(m.ok, isFalse);
      expect(m.windows, isEmpty);
    });

    test('wsok：带实时矩形', () {
      final m = parseWindowHostMessage(
              '{"v":1,"t":"wsok","w":{"hwnd":7,"title":"Word","process":"WINWORD.EXE","left":100,"top":50,"width":1200,"height":800,"min":false}}')
          as WindowSelectedMessage;
      expect(m.info.hwnd, 7);
      expect(m.info.left, 100);
      expect(m.info.width, 1200);
      expect(m.info.minimized, isFalse);
    });

    test('wg：窗口已关闭', () {
      final m = parseWindowHostMessage('{"v":1,"t":"wg","hwnd":7}')
          as WindowGoneMessage;
      expect(m.hwnd, 7);
    });

    test('wst：三种状态都认得', () {
      for (final s in const ['ok', 'min', 'off']) {
        final m = parseWindowHostMessage('{"v":1,"t":"wst","state":"$s"}')
            as WindowStateMessage;
        expect(m.state, s);
      }
    });

    test('畸形输入一律返回 null，不抛', () {
      expect(parseWindowHostMessage(''), isNull);
      expect(parseWindowHostMessage('not json'), isNull);
      expect(parseWindowHostMessage('[]'), isNull);
      expect(parseWindowHostMessage('{"v":2,"t":"wn"}'), isNull);
      expect(parseWindowHostMessage('{"v":1,"t":"wg"}'), isNull); // 缺 hwnd
      expect(parseWindowHostMessage('{"v":1,"t":"wg","hwnd":"7"}'), isNull);
      expect(parseWindowHostMessage('{"v":1,"t":"wst"}'), isNull); // 缺 state
      expect(parseWindowHostMessage('{"v":1,"t":"wsok","w":"x"}'), isNull);
      expect(parseWindowHostMessage('{"v":1,"t":"nope"}'), isNull);
    });

    test('超长报文直接丢（窗口标题可能很长，但 64KB 上限足够）', () {
      final huge =
          '{"v":1,"t":"wg","hwnd":1,"pad":"${'a' * 70000}"}';
      expect(parseWindowHostMessage(huge), isNull);
    });
  });

  // ---------------------------------------------------------------- 数据模型

  group('RemoteWindowInfo.fromJson 宽容取值', () {
    test('字段类型不对时回落默认值，不抛 CastError', () {
      final w = RemoteWindowInfo.fromJson(<String, dynamic>{
        'hwnd': 'oops',
        'title': 42,
        'left': null,
        'min': 'yes',
      });
      expect(w.hwnd, 0);
      expect(w.title, '42');
      expect(w.left, 0);
      expect(w.minimized, isFalse);
    });
  });

  // ---------------------------------------------------------------- 真机 smoke（仅 Windows）

  group('窗口枚举真机 smoke（仅本机 Windows 跑，CI 是 ubuntu 自动跳过）', () {
    // 🔴 这个守卫不能省：CI runner 是 ubuntu，没有 user32.dll。
    //    在真机上（龙哥那台被控电脑）它会真枚举，是人肉验证入口。
    if (!Platform.isWindows) return;

    test('能枚举出至少一个窗口，且字段自洽', () {
      final wins = enumerateWindows();
      expect(wins, isNotEmpty,
          reason: '一台开着的电脑不可能一个可见顶层窗口都没有');
      for (final w in wins) {
        expect(w.hwnd, greaterThan(0));
        expect(w.title, isNotEmpty);
        expect(w.hwndPtr.address, w.hwnd);
        if (!w.minimized) {
          expect(w.width, greaterThan(0));
          expect(w.height, greaterThan(0));
        }
      }
    });

    test('isWindowAlive：列出来的窗口都活着；0 和垃圾句柄算死', () {
      final wins = enumerateWindows();
      for (final w in wins.take(5)) {
        expect(isWindowAlive(w.hwnd), isTrue);
      }
      expect(isWindowAlive(0), isFalse);
      expect(isWindowAlive(0x7FFFFFF0), isFalse);
    });

    test('toJson 的键与 parseWindowHostMessage 吃的键对得上', () {
      // 往返一遍：枚举 → toJson → 当成 wn 报文解析回控制端模型。
      // 键名对不上时这里立刻红，不用等真机联调。
      final wins = enumerateWindows();
      expect(wins, isNotEmpty);
      final json = <String, dynamic>{
        'v': 1,
        't': 'wn',
        'ok': true,
        'win': wins.map((w) => w.toJson()).toList(),
      };
      final m = parseWindowHostMessage(_encode(json))! as WindowListMessage;
      expect(m.ok, isTrue);
      expect(m.windows.length, wins.length);
      expect(m.windows.first.title, wins.first.title);
      expect(m.windows.first.hwnd, wins.first.hwnd);
    });
  });
}

/// 测试里不引 dart:convert 的 encode 也行，但报文是字符串，这里现编一个
/// 最小 JSON 序列化（键值都是简单类型）。
String _encode(Map<String, dynamic> m) {
  final b = StringBuffer('{');
  var first = true;
  m.forEach((k, v) {
    if (!first) b.write(',');
    first = false;
    b.write('"$k":');
    if (v is String) {
      b.write('"${v.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"');
    } else if (v is List) {
      b.write('[${(v).map((e) => _encode(e as Map<String, dynamic>)).join(',')}]');
    } else {
      b.write('$v');
    }
  });
  b.write('}');
  return b.toString();
}
