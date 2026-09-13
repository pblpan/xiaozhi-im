// 远程协助「控制端」的按键映射单测
//
// 【为什么这一小块值得单独测】
// 这段写错的表象不是报错，而是"对方电脑上按不出 Ctrl+C / Alt+Tab"。
// 用户只会觉得软件难用，且极难复现 —— 键盘映射一旦漏一格，靠联调很难发现
// （鼠标和打字都正常，唯独组合键不行）。所以这里按类逐个锁死。
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/input_inject.dart';
import 'package:xiaozhi_im_client/screens/remote.dart';

void main() {
  const ctrl = LogicalKeyboardKey.controlLeft;
  const ctrlR = LogicalKeyboardKey.controlRight;
  const shiftL = LogicalKeyboardKey.shiftLeft;
  const shiftR = LogicalKeyboardKey.shiftRight;
  const altL = LogicalKeyboardKey.altLeft;
  const altR = LogicalKeyboardKey.altRight;
  const metaL = LogicalKeyboardKey.metaLeft;
  const metaR = LogicalKeyboardKey.metaRight;

  group('修饰键必须被映射（否则做不出任何组合键）', () {
    test('左右 Ctrl 都映射到 VK_CONTROL，右侧带扩展位', () {
      expect(remoteKeyOf(ctrl, null)?.vk, Vk.control);
      expect(remoteKeyOf(ctrlR, null)?.vk, Vk.control);
      expect(remoteKeyOf(ctrlR, null)?.extended, isTrue);
      expect(remoteKeyOf(ctrl, null)?.extended, isFalse);
    });

    test('左右 Shift 映射到 VK_SHIFT', () {
      expect(remoteKeyOf(shiftL, null)?.vk, Vk.shift);
      expect(remoteKeyOf(shiftR, null)?.vk, Vk.shift);
      expect(remoteKeyOf(shiftR, null)?.extended, isTrue);
    });

    test('左右 Alt 映射到 VK_MENU', () {
      expect(remoteKeyOf(altL, null)?.vk, Vk.alt);
      expect(remoteKeyOf(altR, null)?.vk, Vk.alt);
    });

    test('左右 Win/meta 键也映射（Win+D 回桌面这类要用）', () {
      expect(remoteKeyOf(metaL, null)?.vk, Vk.meta);
      expect(remoteKeyOf(metaR, null)?.vk, Vk.meta);
    });

    test('修饰键**不带** char（否则会同时走 Unicode 注入打出怪字符）', () {
      for (final k in [ctrl, ctrlR, shiftL, shiftR, altL, altR, metaL, metaR]) {
        expect(remoteKeyOf(k, 'ignored')?.char, isNull, reason: '$k');
      }
    });
  });

  group('组合键：不能退化成单独一个字符', () {
    test('Ctrl+C 时 character 是控制字符 → 转成虚拟键码而不是原样发送', () {
      // 按住 Ctrl 再按 C，Flutter 给的 character 是 '\x03'（ETX）。
      // 原样发出去的话被控端收到的是一个不可见字符，根本不是复制。
      final k = remoteKeyOf(LogicalKeyboardKey.keyC, '\u0003');
      expect(k?.vk, 0x43, reason: 'VK_C');
      expect(k?.char, isNull);
    });

    test('Ctrl+V 同理', () {
      expect(remoteKeyOf(LogicalKeyboardKey.keyV, '\u0016')?.vk, 0x56);
    });

    test('character 为空时也能靠 keyLabel 推导出字母键', () {
      expect(remoteKeyOf(LogicalKeyboardKey.keyA, null)?.vk, 0x41);
      expect(remoteKeyOf(LogicalKeyboardKey.keyZ, null)?.vk, 0x5A);
      expect(remoteKeyOf(LogicalKeyboardKey.digit1, null)?.vk, 0x31);
    });

    test('多字符标签不会被误推键（F1 不该变成 VK_F）', () {
      // 这是加 length==1 这个判断的原因：'F1' 取首字母会得到 'F'
      expect(remoteKeyOf(LogicalKeyboardKey.f1, null)?.vk, Vk.f1);
      expect(remoteKeyOf(LogicalKeyboardKey.tab, null)?.char, isNull);
    });
  });

  group('普通按键走 Unicode 注入', () {
    test('可打印字符原样传 character', () {
      expect(remoteKeyOf(LogicalKeyboardKey.keyA, 'a')?.char, 'a');
      expect(remoteKeyOf(LogicalKeyboardKey.keyA, 'A')?.char, 'A');
      expect(remoteKeyOf(LogicalKeyboardKey.digit1, '1')?.char, '1');
    });

    test('中文字符也能传（靠的就是 Unicode 注入这一路）', () {
      expect(remoteKeyOf(LogicalKeyboardKey.keyA, '中')?.char, '中');
    });

    test('控制字符不属于可打印字符（0x7F DEL 也不算）', () {
      final del = remoteKeyOf(LogicalKeyboardKey.delete, '\u007F');
      expect(del?.char, isNull);
      expect(del?.vk, Vk.delete, reason: '应落到 Delete 的虚拟键码');
    });
  });

  group('常用控制键与功能键', () {
    test('方向键带扩展位（区分小键盘）', () {
      for (final pair in {
        LogicalKeyboardKey.arrowUp: Vk.up,
        LogicalKeyboardKey.arrowDown: Vk.down,
        LogicalKeyboardKey.arrowLeft: Vk.left,
        LogicalKeyboardKey.arrowRight: Vk.right,
        LogicalKeyboardKey.home: Vk.home,
        LogicalKeyboardKey.end: Vk.end,
        LogicalKeyboardKey.pageUp: Vk.pageUp,
        LogicalKeyboardKey.pageDown: Vk.pageDown,
        LogicalKeyboardKey.delete: Vk.delete,
        LogicalKeyboardKey.insert: Vk.insert,
      }.entries) {
        final k = remoteKeyOf(pair.key, null);
        expect(k?.vk, pair.value, reason: '${pair.key}');
        expect(k?.extended, isTrue, reason: '${pair.key} 应带扩展位');
      }
    });

    test('Tab / Backspace / Enter / Esc / 空格', () {
      expect(remoteKeyOf(LogicalKeyboardKey.tab, null)?.vk, Vk.tab);
      expect(remoteKeyOf(LogicalKeyboardKey.backspace, null)?.vk, Vk.backspace);
      expect(remoteKeyOf(LogicalKeyboardKey.enter, null)?.vk, Vk.enter);
      expect(remoteKeyOf(LogicalKeyboardKey.escape, null)?.vk, Vk.escape);
      expect(remoteKeyOf(LogicalKeyboardKey.space, null)?.vk, Vk.space);
    });

    test('F1..F12 全部可用且连续', () {
      final keys = [
        LogicalKeyboardKey.f1, LogicalKeyboardKey.f2, LogicalKeyboardKey.f3,
        LogicalKeyboardKey.f4, LogicalKeyboardKey.f5, LogicalKeyboardKey.f6,
        LogicalKeyboardKey.f7, LogicalKeyboardKey.f8, LogicalKeyboardKey.f9,
        LogicalKeyboardKey.f10, LogicalKeyboardKey.f11, LogicalKeyboardKey.f12,
      ];
      for (var i = 0; i < keys.length; i++) {
        expect(remoteKeyOf(keys[i], null)?.vk, Vk.f1 + i, reason: 'F${i + 1}');
      }
      for (final k in keys) {
        expect(remoteKeyOf(k, null), isNotNull, reason: '$k 不能返回 null');
      }
    });
  });

  group('健壮性', () {
    test('认不出来的键返回 null（调用方按 ignored 处理，不崩）', () {
      expect(remoteKeyOf(LogicalKeyboardKey.capsLock, null), isNull);
      expect(remoteKeyOf(LogicalKeyboardKey.pause, null), isNull);
    });

    test('空字符串 character 不会构造出空 char', () {
      expect(remoteKeyOf(LogicalKeyboardKey.keyA, '')?.char, isNull);
    });
  });
}
