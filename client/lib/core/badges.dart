import 'package:flutter/foundation.dart';

/// 导航角标：底部标签栏要显示的未读数、待办数。
///
/// 为什么要单独放一个单例：这些数字**由会话列表页写入、由外壳（HomeShell）读取**。
/// 如果让外壳直接持有列表页内部的通知器，两边就有了 dispose 先后顺序的耦合
/// （外壳销毁时要摘监听，而通知器可能已经被子页面销毁 → 调试模式下直接断言失败）。
/// 放到一个不随页面生灭的单例里，两边互不依赖，也不用操心谁先销毁。
///
/// 与 SoundService / CallService 同款做法，保持项目里"跨页共享状态放单例"的一致风格。
class Badges {
  static final Badges instance = Badges._();
  Badges._();

  /// 未读消息总数（免打扰会话不计入 —— 用户明确说不想被打扰，还标红点等于没听他的）
  final ValueNotifier<int> unread = ValueNotifier<int>(0);

  /// 未读里是否有人 @我（角标改用品牌红，提示"这条得看"）
  final ValueNotifier<bool> mention = ValueNotifier<bool>(false);

  /// 待处理的好友申请数（「通讯录」标签的角标）
  final ValueNotifier<int> pendingFriends = ValueNotifier<int>(0);

  /// 会话列表加载完后写入一次。传 -1 表示"数据不可用，保持原样"。
  void setUnread(int total, {required bool hasMention}) {
    if (total < 0) return;
    if (unread.value != total) unread.value = total;
    if (mention.value != hasMention) mention.value = hasMention;
  }

  void setPendingFriends(int n) {
    if (n < 0) return;
    if (pendingFriends.value != n) pendingFriends.value = n;
  }

  /// 退出登录时清空：否则换个账号登进来会先看到上一个人的未读数
  void clear() {
    unread.value = 0;
    mention.value = false;
    pendingFriends.value = 0;
  }
}
