/// 时间格式化。服务端 created_at / last_at 存的是毫秒时间戳（Date.now()）。
class TimeFmt {
  /// 毫秒 → DateTime（老数据若存成秒会自动放大 1000 倍）
  static DateTime fromMs(int ts) => ts < 100000000000
      ? DateTime.fromMillisecondsSinceEpoch(ts * 1000)
      : DateTime.fromMillisecondsSinceEpoch(ts);

  static String _pad(int n) => n.toString().padLeft(2, '0');

  /// 14:05
  static String hhmm(int ts) {
    final d = fromMs(ts);
    return '${_pad(d.hour)}:${_pad(d.minute)}';
  }

  /// 会话列表右侧：今天显示时间，昨天显示"昨天"，本周显示周几，更早显示日期
  static String listStamp(int ts) {
    final d = fromMs(ts);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(d.year, d.month, d.day);
    final diff = today.difference(that).inDays;

    if (diff == 0) return hhmm(ts);
    if (diff == 1) return '昨天';
    if (diff < 7) return '周${_weekday(d.weekday)}';
    if (d.year == now.year) return '${d.month}/${d.day}';
    return '${d.year}/${d.month}/${d.day}';
  }

  /// 聊天记录顶部的日期分隔：今天 / 昨天 / 周三 / 2026/9/9
  static String dayLabel(int ts) {
    final d = fromMs(ts);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(d.year, d.month, d.day);
    final diff = today.difference(that).inDays;

    if (diff == 0) return '今天';
    if (diff == 1) return '昨天';
    if (diff < 7) return '周${_weekday(d.weekday)}';
    if (d.year == now.year) return '${d.month}月${d.day}日';
    return '${d.year}年${d.month}月${d.day}日';
  }

  /// 是否同一天（用于判断要不要插日期分隔）
  static bool sameDay(int a, int b) {
    final x = fromMs(a);
    final y = fromMs(b);
    return x.year == y.year && x.month == y.month && x.day == y.day;
  }

  static String _weekday(int w) => const ['一', '二', '三', '四', '五', '六', '日'][w - 1];

  /// 文件大小 1.2MB / 340KB
  static String size(int bytes) {
    if (bytes <= 0) return '';
    if (bytes >= 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(1)}MB';
    }
    return '${(bytes / 1024).toStringAsFixed(0)}KB';
  }

  const TimeFmt._();
}
