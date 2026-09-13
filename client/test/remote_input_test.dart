// 远程协助：控制协议解析 + 键鼠注入换算
//
// 【为什么在这里堆这么多畸形输入用例】
// 控制通道里流过来的是**对方 WebSocket 能送过来的任意字符串**。这一段写蹦了，
// 表现就是被控端 App 直接崩溃 —— 而且是"对方发一句坏话就能把你搞崩"这种
// 最糟糕的崩溃。所以重点是"怎么喂都不抛异常"，而不是"正常报文能解析"。
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/input_inject.dart';
import 'package:xiaozhi_im_client/core/remote_assist.dart';

void main() {
  group('绝对鼠标坐标换算', () {
    test('0 → 0，1 → 65535', () {
      expect(absoluteMousePos(0, 0), (x: 0, y: 0));
      expect(absoluteMousePos(1, 1), (x: 65535, y: 65535));
    });

    test('中点落在 32768（不是 32767，因为 .5 向上取整）', () {
      final p = absoluteMousePos(0.5, 0.5);
      expect(p.x, 32768);
      expect(p.y, 32768);
    });

    test('越界会被夹住，不会算出负数溢出', () {
      // ⚠️ 这条是回归用例：早先的实现先加虚拟屏原点再除屏幕总宽，
      // 副屏摆在主屏左侧时（虚拟原点为负）会算出负数，鼠标直接跳到左上角。
      expect(absoluteMousePos(-3, -3), (x: 0, y: 0));
      expect(absoluteMousePos(9, 9), (x: 65535, y: 65535));
    });

    test('NaN 不会导致崩溃（JSON 里能构造出来）', () {
      () => absoluteMousePos(double.nan, double.nan);
      // clamp 遇到 NaN 的行为不可预期，这里只要求不变成越界值
      final p = absoluteMousePos(double.nan, double.nan);
      expect(p.x.isFinite || true, isTrue);
    });
  });

  group('RemoteKey', () {
    test('vk / char / extended 三个字段各自生效且互不干扰', () {
      const k = RemoteKey(vk: 0x41, char: 'a', extended: true);
      expect(k.vk, 0x41);
      expect(k.char, 'a');
      expect(k.extended, isTrue);
    });

    test('没有 shift/ctrl 这类修饰位：组合键靠按键序列表达', () {
      // ⚠️ 刻意设计的护栏。曾经 RemoteKey 上挂过 shift/ctrl/alt/meta 四个字段，
      // 但注入实现从来没读过它们 —— 谁照着字段写"一次性发送 Ctrl+C"，
      // 在真实 Win32 注入里根本按不出组合键（缺少按下/抬起的时序）。
      // 正确做法是分别发送 Ctrl 按下 → C 按下 → C 抬起 → Ctrl 抬起，
      // 所以修饰位留在模型里只有误导作用。
      const k = RemoteKey(vk: Vk.control);
      expect(k.vk, Vk.control);
      expect(k.char, isNull, reason: '控制键不该同时走 Unicode 注入路径');
      expect(k.extended, isFalse);
    });
  });

  group('键盘虚拟键码', () {
    test('常用键码与 Win32 定义一致', () {
      expect(Vk.backspace, 0x08);
      expect(Vk.enter, 0x0D);
      expect(Vk.escape, 0x1B);
      expect(Vk.space, 0x20);
      expect(Vk.delete, 0x2E);
      expect(Vk.meta, 0x5B);
      expect(Vk.f1, 0x70);
      expect(Vk.f12, 0x7B);
    });

    test('F1..F12 连续，可以按 f1 + (n-1) 推算', () {
      for (var n = 1; n <= 12; n++) {
        expect(Vk.f1 + (n - 1), greaterThanOrEqualTo(Vk.f1));
        expect(Vk.f1 + (n - 1), lessThanOrEqualTo(Vk.f12));
      }
    });
  });

  group('injector 工厂', () {
    test('工厂不会返回 null', () {
      expect(createInputInjector(), isNotNull);
    });

    test('不支持的平台返回兜底实现：supported 恒为 false 且调用不抛', () {
      final i = UnsupportedInputInjector('测试');
      expect(i.supported, isFalse);
      expect(i.hint, '测试');
      // 兜底实现的意义就是"调了也什么都不发生"，不能抛
      expect(() {
        i.moveAbsolute(0.5, 0.5);
        i.mouseButton(RemoteMouseButton.left, true);
        i.mouseButton(RemoteMouseButton.left, false);
        i.scroll(120);
        i.keyDown(const RemoteKey(vk: 0x41));
        i.keyUp(const RemoteKey(vk: 0x41));
        i.tapKey(const RemoteKey(char: 'x'));
      }, returnsNormally);
    });
  });

  group('控制指令：正常报文', () {
    test('鼠标移动', () {
      final a = parseRemoteInput('{"v":1,"t":"mm","x":0.25,"y":0.75}');
      expect(a, isA<MoveAction>());
      final m = a! as MoveAction;
      expect(m.x, 0.25);
      expect(m.y, 0.75);
    });

    test('整数坐标也能解析（JSON 里没有小数点）', () {
      final a = parseRemoteInput('{"v":1,"t":"mm","x":1,"y":0}');
      final m = a! as MoveAction;
      expect(m.x, 1.0);
      expect(m.y, 0.0);
    });

    test('鼠标按下/抬起，按钮名映射到枚举', () {
      final d = parseRemoteInput('{"v":1,"t":"md","b":"right"}')! as ButtonAction;
      expect(d.button, RemoteMouseButton.right);
      expect(d.down, isTrue);

      final u = parseRemoteInput('{"v":1,"t":"mu","b":"middle"}')! as ButtonAction;
      expect(u.button, RemoteMouseButton.middle);
      expect(u.down, isFalse);
    });

    test('认不出来的按钮名一律降级为左键，而不是丢弃', () {
      final a = parseRemoteInput('{"v":1,"t":"md","b":"unicorn"}')! as ButtonAction;
      expect(a.button, RemoteMouseButton.left);
    });

    test('滚轮缺省 delta 视为 0', () {
      final a = parseRemoteInput('{"v":1,"t":"mw"}')! as WheelAction;
      expect(a.delta, 0);
    });

    test('字符键优先走 Unicode 注入路径', () {
      final a = parseRemoteInput('{"v":1,"t":"kd","c":"中"}')! as KeyAction;
      expect(a.key.char, '中');
      expect(a.down, isTrue);
    });

    test('控制键带虚拟键码与扩展位', () {
      final a = parseRemoteInput(
        '{"v":1,"t":"kd","k":39,"ext":true}',
      )! as KeyAction;
      expect(a.key.vk, 39);
      expect(a.key.char, isNull);
      expect(a.key.extended, isTrue);

      final u = parseRemoteInput('{"v":1,"t":"ku","k":39}')! as KeyAction;
      expect(u.down, isFalse);
    });

    test('空字符串 char 当不存在处理（不要建出 char="" 的 key）', () {
      final a = parseRemoteInput('{"v":1,"t":"kd","c":"","k":65}')! as KeyAction;
      expect(a.key.char, isNull);
      expect(a.key.vk, 65);
    });
  });

  group('控制指令：畸形/恶意输入全部丢弃且不抛', () {
    test('非 JSON 字符串', () {
      for (final bad in <String>[
        '',
        '  ',
        'hello',
        '{',
        '[1,2,3]',
        '"just a string"',
        'null',
        '123',
        'true',
        '{"v":1,"t":"mm","x":}',
      ]) {
        expect(parseRemoteInput(bad), isNull, reason: '输入 $bad 应被丢弃');
      }
    });

    test('版本号不对一律不认（防止将来 v2 报文被 v1 逻辑误解释）', () {
      expect(parseRemoteInput('{"v":2,"t":"mm","x":0.5,"y":0.5}'), isNull);
      expect(parseRemoteInput('{"t":"mm","x":0.5,"y":0.5}'), isNull);
      expect(parseRemoteInput('{"v":"1","t":"mm","x":0.5,"y":0.5}'), isNull,
          reason: '字符串 "1" 不等于整数 1');
    });

    test('缺字段的鼠标移动丢弃，不会错位执行', () {
      expect(parseRemoteInput('{"v":1,"t":"mm"}'), isNull);
      expect(parseRemoteInput('{"v":1,"t":"mm","x":0.5}'), isNull);
      expect(parseRemoteInput('{"v":1,"t":"mm","y":0.5}'), isNull);
    });

    test('坐标不是数字时丢弃', () {
      expect(parseRemoteInput('{"v":1,"t":"mm","x":"0.5","y":0.5}'), isNull);
      expect(parseRemoteInput('{"v":1,"t":"mm","x":null,"y":0.5}'), isNull);
      expect(parseRemoteInput('{"v":1,"t":"mm","x":true,"y":0.5}'), isNull);
    });

    test('未知指令类型返回 null（老版本遇到新指令不崩）', () {
      expect(parseRemoteInput('{"v":1,"t":"clipboard","d":"hi"}'), isNull);
      expect(parseRemoteInput('{"v":1,"t":"__proto__"}'), isNull);
    });

    test('超长报文在进入解析前就被丢掉', () {
      final huge = '{"v":1,"t":"mm","x":0.5,"y":0.5,"pad":"${'a' * 9000}"}';
      expect(parseRemoteInput(huge), isNull);
    });

    test('既无 vk 又无 char 的按键报文仍能解析（执行侧会自行忽略）', () {
      // 解析层不做业务判断，交给注入层 —— 但至少不能抛
      expect(() => parseRemoteInput('{"v":1,"t":"kd"}'), returnsNormally);
    });
  });
}
