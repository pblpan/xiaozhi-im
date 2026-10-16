import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xiaozhi_im_client/core/theme.dart';

/// WCAG 相对亮度。
double _lum(Color c) {
  double f(int v) {
    final s = v / 255.0;
    return s <= 0.03928
        ? s / 12.92
        : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * f(c.red) + 0.7152 * f(c.green) + 0.0722 * f(c.blue);
}

/// 两色对比度（1.0 = 完全一样，21.0 = 黑白）。
double _contrast(Color a, Color b) {
  final l1 = _lum(a);
  final l2 = _lum(b);
  final hi = math.max(l1, l2);
  final lo = math.min(l1, l2);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  // 这些用例会改 AppColors / AppSkin 的全局静态状态。
  // 每个用例结束都还原成默认皮肤，避免污染同进程里的其它测试。
  tearDown(() => AppSkin.apply(AppPalette.dark));

  group('皮肤调色板', () {
    test('六套皮肤，名字唯一，老名字仍在', () {
      final names = AppPalette.all.map((p) => p.name).toList();
      expect(AppPalette.all.length, 6);
      expect(names.toSet().length, names.length,
          reason: '名字重复会让持久化认错皮肤');
      // 🔴 v0.28.5 就已经把 'dark'/'light' 写进用户机器了，改名 = 升级后皮肤被打回默认
      expect(names, contains('dark'));
      expect(names, contains('light'));
    });

    test('byName 能认回每一套', () {
      for (final p in AppPalette.all) {
        expect(identical(AppPalette.byName(p.name), p), isTrue,
            reason: p.name);
      }
    });

    test('认不出 / 空 / null 一律回落默认，不抛', () {
      // 手改配置文件、将来下线某套皮肤都会走到这里。抛异常 = App 起不来。
      expect(AppPalette.byName(null), AppPalette.dark);
      expect(AppPalette.byName(''), AppPalette.dark);
      expect(AppPalette.byName('nope'), AppPalette.dark);
    });

    test('明暗分组 3 深 3 浅，且不是靠"是不是 light"猜的', () {
      expect(AppPalette.all.where((p) => p.isLight).length, 3);
      expect(AppPalette.all.where((p) => !p.isLight).length, 3);
      // 🔴 回归护栏：早期 isLight 写成 `palette == AppPalette.light`。
      //    浅色从 1 套变 3 套之后，那句会把纸白/暖沙误判成深色 ——
      //    状态栏图标反色、背景渐变方向反了。
      expect(AppPalette.paper.isLight, isTrue);
      expect(AppPalette.sand.isLight, isTrue);
      expect(AppPalette.midnight.isLight, isFalse);
      expect(AppPalette.ink.isLight, isFalse);
    });

    test('AppSkin.isLight 跟着当前皮肤走', () {
      AppSkin.apply(AppPalette.sand);
      expect(AppSkin.isLight, isTrue);
      AppSkin.apply(AppPalette.midnight);
      expect(AppSkin.isLight, isFalse);
    });

    test('AppColors 静态字段被整套重写（换肤的原理）', () {
      AppSkin.apply(AppPalette.midnight);
      expect(AppColors.bg, AppPalette.midnight.bg);
      expect(AppColors.brand, AppPalette.midnight.brand);
      AppSkin.apply(AppPalette.sand);
      expect(AppColors.bg, AppPalette.sand.bg);
      expect(AppColors.brand, AppPalette.sand.brand);
    });
  });

  group('皮肤可读性（手写色值的护栏）', () {
    test('每套皮肤的文字对比度够看', () {
      for (final p in AppPalette.all) {
        expect(_contrast(p.text, p.bg), greaterThan(7.0),
            reason: '${p.label}：正文在背景上');
        expect(_contrast(p.textSub, p.bg), greaterThan(4.5),
            reason: '${p.label}：次要文字在背景上');
        expect(_contrast(p.textWeak, p.bg), greaterThan(3.0),
            reason: '${p.label}：弱化文字在背景上');
      }
    });

    test('每套皮肤的层次没有塌成一片', () {
      for (final p in AppPalette.all) {
        expect(p.surface, isNot(p.bg),
            reason: '${p.label}：surface 与 bg 同色 = 卡片看不出边界');
        expect(p.bubbleOther, isNot(p.bg),
            reason: '${p.label}：对方气泡与背景同色 = 气泡消失');
        expect(p.brand, isNot(p.brand2),
            reason: '${p.label}：渐变两端同色 = 渐变退化成纯色');
      }
    });

    test('品牌色上的白字还看得见', () {
      // 门槛取 2.0 而不是 WCAG 的 3.0：既有的极夜青（#10B981 配白字）本来就是 2.56，
      // 这一轮不改动龙哥已经看惯的既有色值，只保证新加的皮肤不比它更差。
      for (final p in AppPalette.all) {
        expect(_contrast(Colors.white, p.brand), greaterThan(2.0),
            reason: '${p.label}：主按钮上的白字');
      }
    });
  });

  group('主题装配', () {
    test('ThemeData 亮度跟着皮肤走', () {
      expect(AppTheme.build(AppPalette.sand).brightness, Brightness.light);
      expect(AppTheme.build(AppPalette.paper).brightness, Brightness.light);
      expect(AppTheme.build(AppPalette.ink).brightness, Brightness.dark);
      expect(AppTheme.build(AppPalette.midnight).brightness, Brightness.dark);
    });

    test('动态模块语义色跟着皮肤走，不是写死深浅两套', () {
      // 🔴 回归护栏：早期 build() 里是 `p == light ? AppSemantic.light : dark`，
      //    加到六套之后那句会把四套新皮肤全错配成深色令牌 ——
      //    动态页面在浅色皮肤上变成深底浅字，等于换肤失效。
      final s = AppSemantic.forPalette(AppPalette.sand);
      expect(s.muted, AppPalette.sand.textSub);
      expect(s.cardBg, AppPalette.sand.surface);

      final registered =
          AppTheme.build(AppPalette.paper).extension<AppSemantic>();
      expect(registered, isNotNull);
      expect(registered!.cardBg, AppPalette.paper.surface);
      expect(registered.muted, AppPalette.paper.textSub);
    });
  });

  group('皮肤持久化', () {
    test('老版本存的 light 升级后还认得', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({'xz_app_skin': 'light'});
      await AppSkin.load();
      expect(identical(AppSkin.palette, AppPalette.light), isTrue);
    });

    test('存新皮肤的名字，冷启动能还原', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      await AppSkin.set(AppPalette.paper);
      // 模拟冷启动：内存打回默认，再从盘上读回来
      AppSkin.apply(AppPalette.dark);
      await AppSkin.load();
      expect(identical(AppSkin.palette, AppPalette.paper), isTrue);
    });

    test('存的是名字而不是"浅/深"两个字（否则六套只能记住两套）', () async {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      await AppSkin.set(AppPalette.midnight);
      final sp = await SharedPreferences.getInstance();
      expect(sp.getString('xz_app_skin'), 'midnight');
    });
  });
}
