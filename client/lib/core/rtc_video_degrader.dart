// 视频质量动态降级控制器（UU-c）。
//
// 解决的问题：网络变差时，若还死扛高清，画面会卡成幻灯片、甚至把连接拖死。
// 这里周期性读 getStats() 监测**发送端** outbound-rtp 的丢包率，丢包高就逐级
// 下调 maxBitrate / maxFramerate / scaleResolutionDownBy（用 setParameters）；
// 网络恢复后带滞回地上调，避免反复横跳。
//
// 编解码两端协商本身由 WebRTC 的 SDP 协商完成（无需我们手动交换），
// 这一层只负责"协商完之后，按网络实况动态降级"。
//
// ⚠️ flutter_webrtc 的 getStats / setParameters 跨版本形态不一，这里全部做
//    容错：getStats 的 Map / List 两种返回、StatsReport 的两种 values 形态都认；
//    任何一步拿不到数据就跳过，绝不让统计逻辑把通话搞崩。

import 'dart:async';

import 'package:flutter_webrtc/flutter_webrtc.dart';

class _Tier {
  const _Tier({this.maxBitrate, this.maxFramerate, this.scale});
  final int? maxBitrate; // kbps，null = 不限制
  final int? maxFramerate; // fps，null = 不限制
  final int? scale; // scaleResolutionDownBy，null = 1
}

class RtcVideoDegrader {
  RtcVideoDegrader(this.pc, this.sender, {this.onChange});

  final RTCPeerConnection pc;
  final RTCRtpSender sender;
  final void Function(int level, String reason)? onChange;

  // 0 = 不限制（默认）；数字越大越省带宽、越糊。
  static const List<_Tier> tiers = <_Tier>[
    _Tier(),
    _Tier(maxBitrate: 1500, maxFramerate: 20, scale: 1),
    _Tier(maxBitrate: 800, maxFramerate: 15, scale: 1),
    _Tier(maxBitrate: 400, maxFramerate: 10, scale: 2),
    _Tier(maxBitrate: 200, maxFramerate: 8, scale: 2),
  ];

  int _level = 0;
  Timer? _timer;
  int _bad = 0;
  int _good = 0;
  int _prevSent = 0;
  int _prevLost = 0;

  /// 手动锁定的档位。null = 交给自动（默认）。
  ///
  /// 为什么要"锁"而不是"调一次"：自动降级每 3 秒跑一轮，不锁的话
  /// 用户手选的档位下一轮就被网络状况覆盖回去了。
  int? _locked;

  /// 当前档位（0=原画不限制）。手动锁定后它就是锁定值。
  int get level => _level;

  bool get locked => _locked != null;

  /// 手动锁定档位；传 null 恢复自动。
  Future<void> lock(int? level) async {
    if (level == null) {
      _locked = null;
      onChange?.call(_level, '恢复自动');
      return;
    }
    _locked = level.clamp(0, tiers.length - 1);
    _level = _locked!;
    await _apply();
    onChange?.call(_level, '手动');
  }
  void start({Duration interval = const Duration(seconds: 3)}) {
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => _tick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    // 锁定了就完全不看网络 —— 用户说"就要这个画质"时，
    // 自动策略再跳出来改是违背指令。
    if (_locked != null) return;
    try {
      final dynamic stats = await pc.getStats();
      int? sent;
      int? lost;
      void visit(dynamic report) {
        final type = _field(report, 'type')?.toString();
        if (type != 'outbound-rtp') return;
        final kind = _field(report, 'kind')?.toString() ??
            _field(report, 'mediaType')?.toString();
        if (kind != 'video') return;
        sent = _int(_field(report, 'packetsSent'));
        lost = _int(_field(report, 'packetsLost'));
      }

      if (stats is Map) {
        for (final v in stats.values) visit(v);
      } else if (stats is List) {
        for (final v in stats) visit(v);
      }
      if (sent == null || lost == null) return;

      final dSent = sent! - _prevSent;
      final dLost = lost! - _prevLost;
      _prevSent = sent!;
      _prevLost = lost!;
      if (dSent <= 0) return;

      final lossRate = dLost / (dSent + dLost);
      if (lossRate > 0.05) {
        _good = 0;
        _bad++;
        if (_bad >= 2 && _level < tiers.length - 1) {
          _level++;
          _bad = 0;
          await _apply();
          onChange?.call(_level, '丢包率 ${(lossRate * 100).toStringAsFixed(1)}%');
        }
      } else {
        _bad = 0;
        _good++;
        if (_good >= 4 && _level > 0) {
          _level--;
          _good = 0;
          await _apply();
          onChange?.call(_level, '网络恢复');
        }
      }
    } catch (_) {
      // 统计接口拿不到数据就跳过，绝不影响通话
    }
  }

  Future<void> _apply() async {
    final t = tiers[_level];
    try {
      // flutter_webrtc 的 setParameters 收的是 RTCRtpParameters 对象（不是裸 Map）
      await sender.setParameters(RTCRtpParameters(
        encodings: <RTCRtpEncoding>[
          RTCRtpEncoding(
            maxBitrate: t.maxBitrate != null ? t.maxBitrate! * 1000 : null,
            maxFramerate: t.maxFramerate,
            scaleResolutionDownBy: t.scale?.toDouble(),
          ),
        ],
      ));
    } catch (_) {
      // 某些平台/版本不支持 setParameters 就忽略，不影响主流程
    }
  }

  // ---- 兼容不同 getStats 返回形态 ----

  static dynamic _field(dynamic report, String key) {
    if (report is Map) return report[key];
    final values = report?.values;
    if (values is Map) return values[key];
    if (values is List) {
      for (final e in values) {
        if (e is Map && e['key'] == key) return e['value'];
      }
    }
    return null;
  }

  static int? _int(dynamic v) => v is num ? v.toInt() : null;
}
