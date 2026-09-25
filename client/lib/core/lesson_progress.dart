/// 培训课时的**真进度**：把播放器的每一秒折算成"到底看了多少"。
///
/// ── 为什么不能只看"播放位置" ────────────────────────────────
/// 老口径是"课件打开成功就记完成"，等于点开就走也算学完了 —— 完成率是假的。
/// 换成"看到第几秒"也不行：进度条一拖就到 95%，拖一下就能拿完成，
/// 门禁（学到 X% 才能考试）等于没有门禁。
///
/// 所以这里记两个量，各管一摊：
///   · `positionSec` —— **到的最远处**，只用来续播，**不做判据**；
///   · `watchedSec`  —— **真看进去的秒数**，只看它判完成。
///
/// ── `watchedSec` 怎么防"拖进度条" ───────────────────────────
/// 每次 tick 只承认「位置前进量」，但这个量**不能超过真实流逝时间 × maxRate**：
///   · 正常 1 倍速播：前进量 ≈ 真实时间，全额计入；
///   · 2 倍速看：前进量 = 2 × 真实时间，正好卡在上限，全额计入（倍速不该被惩罚）；
///   · 拖到 20 分钟处：前进量 1200 秒，而真实只过了 1 秒 → 只认 2 秒。
/// 于是"拖"和"看"在数字上彻底分开，且不需要去猜播放器有没有倍速。
///
/// ⚠️ `maxRate` 是"允许的最快速度"，不是"允许偷懒的比例"。
///    写成 3 就能容忍 3 倍速；写成 1 会让开倍速的人永远毕不了业。
library;

/// 真进度的口径常量。改这里之前先想清楚门禁会跟着变。
class LessonWatchRules {
  /// 看满总时长的这个比例，才算"学完"。
  ///
  /// 不留到 100% 是刻意的：片尾/黑帧那几秒没人会盯着看完，
  /// 逼到 100% 只会招来"我明明看完了却不让考试"的投诉。
  static const double doneRatio = 0.9;

  /// 允许的最快播放速度（倍）。见文件头：它是防拖动的闸门，也是倍速的上限。
  static const int maxRate = 2;

  /// 需要真看到多少秒才算完成。时长未知时返回 0（= 没有判据，别拿 0 当"已达成"）。
  static int requiredSec(int durationSec) =>
      durationSec <= 0 ? 0 : (durationSec * doneRatio).floor();
}

/// 一次观看的累加器。**纯 Dart，不碰播放器**，所以能单测。
class LessonWatch {
  LessonWatch({
    required this.durationSec,
    int positionSec = 0,
    int watchedSec = 0,
  })  : _positionSec = positionSec < 0 ? 0 : positionSec,
        _watchedSec = watchedSec < 0 ? 0 : watchedSec;

  /// 有效时长。服务端没标注时长时用播放器报上来的实际时长补。
  int durationSec;

  int _positionSec;
  int _watchedSec;
  int _lastPos = 0;

  /// 到的最远处（单调不回退）。只用于续播。
  int get positionSec => _positionSec;

  /// 真看进去的秒数。判完成只看它。
  int get watchedSec => _watchedSec;

  /// 需要看到的秒数；0 = 时长未知，此时 `done` 恒为 false（不许糊弄成"已完成"）。
  int get requiredSec => LessonWatchRules.requiredSec(durationSec);

  /// 完成百分比（0~100）。用 `watchedSec / requiredSec`，不是播放位置 ——
  /// 拿位置算就是"拖一拖就 100%"，又回到老问题。
  int get percent {
    final need = requiredSec;
    if (need <= 0) return 0;
    // ⚠️ 不写 `.clamp(0,100)`：int 上的 clamp 返回的是 num，赋值给 int 会类型报错。
    final v = ((_watchedSec / need) * 100).floor();
    return v < 0 ? 0 : (v > 100 ? 100 : v);
  }

  bool get done => requiredSec > 0 && _watchedSec >= requiredSec;

  /// 续播起点：已经在末尾附近就从头开始（差最后几秒不算"没看完"，
  /// 但从 99% 续播出去会立刻播完，反而看不到片尾，所以留 5% 的余量）。
  int get resumeSec {
    if (durationSec <= 0) return 0;
    return _positionSec >= (durationSec * 0.95).floor() ? 0 : _positionSec;
  }

  /// 跳转（续播/手动拖）。**跳转过去的片段不算看过** ——
  /// 所以这里把 `_lastPos` 一起挪走，否则下一 tick 会把整段跳过的时长算成已看。
  void seekTo(int pos) {
    final v = pos < 0 ? 0 : pos;
    _lastPos = v;
    if (v > _positionSec) _positionSec = v;
  }

  /// 服务端没标时长时，用播放器实际时长补上。
  /// 只补不缩：有的片子在初始化早期会先报一个偏小的时长。
  void noteDuration(int d) {
    if (d > durationSec) durationSec = d;
  }

  /// 每秒调一次。
  ///
  /// [positionSec] 播放器当前位置；[elapsedSec] 距上次 tick 的真实秒数；
  /// [playing] 是否真的在播（暂停/缓冲时不算看）。
  void tick({
    required bool playing,
    required int positionSec,
    required int elapsedSec,
  }) {
    final prev = _lastPos;
    _lastPos = positionSec;
    if (positionSec > _positionSec) _positionSec = positionSec;
    if (!playing || elapsedSec <= 0) return;

    final delta = positionSec - prev;
    if (delta <= 0) return; // 没往前走（缓冲/卡住）不计
    final cap = elapsedSec * LessonWatchRules.maxRate;
    _watchedSec += delta > cap ? cap : delta;
  }
}
