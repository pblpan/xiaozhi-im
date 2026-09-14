import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/badges.dart';
import 'package:xiaozhi_im_client/core/theme.dart';
import 'package:xiaozhi_im_client/screens/home_shell.dart';

/// 导航角标的**真渲染**测试。
///
/// 为什么必须真渲染而不是只看代码：角标接的是两个独立的通知器（未读数 / @提醒）。
/// 只订其中一个的话，另一种变化不会重建 —— 表现是"有人 @我 了但角标还是灰的"。
/// 这种错在 `flutter analyze` 阶段完全看不出来（类型都对），只有真的渲染一遍、
/// 真的改通知器的值，才能发现。
void main() {
  Future<void> pump(WidgetTester t, HomeTab tab) => t.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(body: Center(child: NavBadgeIcon(tab: tab, active: true))),
        ),
      );

  setUp(() => Badges.instance.clear());

  testWidgets('未读为 0 时不显示角标（没消息还挂个"0"是噪音）', (t) async {
    await pump(t, homeTabs(true).first);
    expect(find.byType(Badge), findsOneWidget);
    final b = t.widget<Badge>(find.byType(Badge));
    expect(b.isLabelVisible, isFalse);
  });

  testWidgets('未读数变化后角标跟着刷新', (t) async {
    await pump(t, homeTabs(true).first);

    Badges.instance.unread.value = 3;
    await t.pump();
    expect(find.text('3'), findsOneWidget);

    Badges.instance.unread.value = 12;
    await t.pump();
    expect(find.text('12'), findsOneWidget);
    expect(find.text('3'), findsNothing);
  });

  testWidgets('超过 99 显示 99+（不能把标签撑破）', (t) async {
    await pump(t, homeTabs(true).first);
    Badges.instance.unread.value = 250;
    await t.pump();
    expect(find.text('99+'), findsOneWidget);
  });

  testWidgets('未读数不变、只有 @提醒 变化时也要变红（只订一个通知器就会漏掉）',
      (t) async {
    await pump(t, homeTabs(true).first);

    Badges.instance.unread.value = 5;
    await t.pump();
    var badge = t.widget<Badge>(find.byType(Badge));
    expect(badge.label, isNotNull);
    expect(badge.backgroundColor, isNull, reason: '普通未读不标红');

    // 关键：未读数**没变**，只把 @提醒 置上
    Badges.instance.mention.value = true;
    await t.pump();
    badge = t.widget<Badge>(find.byType(Badge));
    expect(badge.backgroundColor, AppColors.danger,
        reason: '@提醒 变化必须触发重建 —— 只订未读通知器的话这里会失败');

    Badges.instance.mention.value = false;
    await t.pump();
    badge = t.widget<Badge>(find.byType(Badge));
    expect(badge.backgroundColor, isNull);
  });

  testWidgets('工作台标签没有角标接进来时不渲染 Badge', (t) async {
    final workbench =
        homeTabs(true).firstWhere((x) => x.label == '工作台');
    await pump(t, workbench);
    expect(find.byType(Badge), findsNothing);
  });

  testWidgets('通讯录标签（普通模式）接的是待处理好友申请数', (t) async {
    final contacts =
        homeTabs(false).firstWhere((x) => x.label == '通讯录');
    await pump(t, contacts);
    Badges.instance.pendingFriends.value = 2;
    await t.pump();
    expect(find.text('2'), findsOneWidget);
  });
}
