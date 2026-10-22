import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/export_format.dart';
import 'package:xiaozhi_im_client/screens/export_settings_page.dart';

/// 格式设定页的 widget 测试（不起服务端：debugSet 直接给定设置）。
///
/// 盯三件容易"改了没生效"的事：
///   ① 每个模块的默认格式显示得对（摆上来就要看得见）；
///   ② 托利多参数动了要出现「保存」（否则用户以为自动存了）；
///   ③ 没接格式体系的模块不许出现在这页（配了没反应比没配更糟）。
void main() {
  testWidgets('模块默认格式 + 托利多参数 + 脏标记', (tester) async {
    ExportSettingsStore.debugSet(ExportSettings.defaults);
    await tester.pumpWidget(const MaterialApp(home: ExportSettingsPage()));
    await tester.pump();

    // 两个接了格式体系的模块都在，默认都是通用 CSV
    expect(find.text('扫码枪盘点'), findsOneWidget);
    expect(find.text('简易盘点'), findsOneWidget);
    expect(find.text('通用 CSV'), findsNWidgets(2));

    // 没接的模块（减货/补货/盘点采集）不许摆上来
    expect(find.text('库房减货'), findsNothing);
    expect(find.text('补货'), findsNothing);

    // 托利多参数区在
    expect(find.text('PLU 号来源'), findsOneWidget);
    expect(find.text('按行序 1,2,3…'), findsOneWidget);
    expect(find.text('组号'), findsOneWidget);
    expect(find.text('保质期（天）'), findsOneWidget);
    expect(find.text('允许秤上改价'), findsOneWidget);

    // 初始没有「保存」（没改动不摆）
    expect(find.text('保存'), findsNothing);

    // 点第一个 + （组号 0→1）→ 出现保存
    await tester.tap(find.byIcon(Icons.add).first);
    await tester.pump();
    expect(find.text('保存'), findsOneWidget);

    // 再点一次 - 回 0 → 脏标记仍在（跟默认值一样也算改过，
    // 重新存一次没坏处；真正该避免的是"存了但没推上去"）
    await tester.tap(find.byIcon(Icons.remove).first);
    await tester.pump();
    expect(find.text('保存'), findsOneWidget);
  });

  testWidgets('模块默认格式可改（弹选择器 → 记住）', (tester) async {
    ExportSettingsStore.debugSet(ExportSettings.defaults);
    await tester.pumpWidget(const MaterialApp(home: ExportSettingsPage()));
    await tester.pump();

    await tester.tap(find.text('扫码枪盘点'));
    await tester.pumpAndSettle();

    // 扫码枪模块四种格式都在选择器里
    expect(find.text('托利多 PLU'), findsOneWidget);
    expect(find.text('托利多 TXT'), findsOneWidget);
    expect(find.text('扫码文本文档'), findsOneWidget);

    await tester.tap(find.text('托利多 PLU'));
    await tester.pumpAndSettle();

    // 行尾变成托利多 PLU，且出现保存
    expect(find.text('托利多 PLU'), findsOneWidget);
    expect(find.text('保存'), findsOneWidget);
  });
}
