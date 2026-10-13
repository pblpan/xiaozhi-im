import 'dart:async';

/// 已读回执的本地广播总线（chat 页 → 会话列表）。
///
/// 解决的问题（2026-10-13 龙哥报的 bug「消息已经读了，但提示小点不是马上
/// 消失」）：`_markRead` 只走 HTTP 上报服务端，会话列表的未读数原本只能等
/// 服务端 `message:read` 广播回来才刷新 —— 宽屏（桌面/平板）布局下聊天页和
/// 会话列表同屏，WS 往返那几百毫秒里红点一直挂着，观感就是"读了还没消"。
///
/// 用法：
///  · chat 页 `_markRead` HTTP 成功后 `ReadBus.instance.fire(conversationId)`；
///  · 会话列表订阅 `ReadBus.instance.onCleared`，本地立即把该会话 unread
///    清零并重算角标，再顺手 `_load()` 用服务端真值校准（防旧响应竞态）。
///
/// 为什么不做成"直接改全局未读状态"而是广播事件：清零的真相在服务端
/// （lastReadId 之后的 ME 可能还有新消息），本地只负责"立刻好看"，校准必须
/// 回到会话列表自己的数据流里做，否则两处各存一份未读数必然走歪。
class ReadBus {
  static final ReadBus instance = ReadBus._();
  ReadBus._();

  final _cleared = StreamController<int>.broadcast();

  /// 某个会话被标记已读（会话 id）。broadcast：多个监听者互不影响。
  Stream<int> get onCleared => _cleared.stream;

  void fire(int conversationId) {
    if (!_cleared.isClosed) _cleared.add(conversationId);
  }
}
