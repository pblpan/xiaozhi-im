import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/badges.dart';
import 'package:xiaozhi_im_client/screens/home_shell.dart';

/// 首页标签结构测试。
///
/// 这一版改动的核心就是"哪些功能进一级入口"。以前所有东西都塞在右上角「⋮」
/// 菜单里（12 项混装），工作模式下同事想打卡要走两步。所以"工作模式必须给
/// 工作台一级入口""普通模式不能长出用不到的工作入口"这两条要能被测试钉住，
/// 而不是只靠看代码。
void main() {
  List<String> labelsOf(bool work) =>
      homeTabs(work).map((t) => t.label).toList();

  test('工作模式：工作台与通讯录都是一级入口', () {
    expect(labelsOf(true), ['消息', '工作台', '通讯录', '我']);
  });

  test('普通模式：不给工作台（家用账号用不上，塞进去只会让人困惑）', () {
    expect(labelsOf(false), ['消息', '通讯录', '我']);
  });

  test('「消息」永远是第一个标签，且角标接的是未读总数', () {
    for (final work in [true, false]) {
      final tabs = homeTabs(work);
      expect(tabs.first.label, '消息');
      expect(tabs.first.badge, same(Badges.instance.unread));
      expect(tabs.first.danger, same(Badges.instance.mention));
    }
  });

  test('角标各自只有一个归属：工作模式的组织通讯录不挂好友申请角标', () {
    final workTabs = homeTabs(true);
    final contacts = workTabs.firstWhere((t) => t.label == '通讯录');
    expect(contacts.badge, isNull,
        reason: '工作模式通讯录是组织架构，没有"待处理好友申请"这回事；'
            '那个数字挂在这里会让人点进去找不到东西');

    final normalTabs = homeTabs(false);
    final normalContacts = normalTabs.firstWhere((t) => t.label == '通讯录');
    expect(normalContacts.badge, same(Badges.instance.pendingFriends));
  });

  test('两个模式都不产生重复标签（重复会让 IndexedStack 下标含义含糊）', () {
    for (final work in [true, false]) {
      final l = labelsOf(work);
      expect(l.toSet().length, l.length, reason: '标签重复：$l');
    }
  });

  test('每个标签都有图标与选中态图标（选中态缺失会看不出当前在哪一页）', () {
    for (final work in [true, false]) {
      for (final t in homeTabs(work)) {
        expect(t.label, isNotEmpty);
        expect(t.activeIcon, isNotNull);
      }
    }
  });
}
