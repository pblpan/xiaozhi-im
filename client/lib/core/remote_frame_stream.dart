// 远程协助「自研画面通道」的帧分片 / 重组协议。
//
// ─────────────────────────────────────────────────────────────
// 【背景：为什么画面不走 RTCVideoView 那条路】
// ─────────────────────────────────────────────────────────────
// Windows 被控端的 WebRTC 桌面采集一直出黑屏（原因见 win_gdi_capture.dart
// 的头部说明）。自研 GDI 抓屏在**同一台机器上实测可用**，于是画面改走
// WebRTC 的 **DataChannel**：抓 → JPEG 编码 → 分片 → 手机端重组 → 贴图。
// 音视频信令、鉴权、ICE 打洞、控制指令通道**全部沿用原来的**，只有
// "画面像素从哪来"换了实现 —— 这样改动面最小，也不会碰已有的安全边界。
//
// 为什么走 DataChannel 而不是复用现有 WebSocket：
//   · DataChannel 是 P2P，手机看电脑的画面不必绕一圈服务器；
//   · 二进制原生支持，不用 base64（那要多花 33% 带宽）。
//
// ─────────────────────────────────────────────────────────────
// 【为什么要分片】
// ─────────────────────────────────────────────────────────────
// 一帧 960x540 的 JPEG 约 35KB，1280x720 会到 60~90KB。而单条 DataChannel
// 消息有上限（SCTP 默认协商值通常 64KB，且实现之间不一致 —— 发超了不一定
// 报错，可能直接丢）。所以统一切成 16KB 一片：既稳稳低于各种上限，
// 又不会让分片数多到每帧几十条消息。
//
// ─────────────────────────────────────────────────────────────
// 【这条通道为什么是"不可靠 + 无序"的】
// ─────────────────────────────────────────────────────────────
// 画面要的是**最新的一帧**，不是完整的历史。如果用可靠有序通道，网络一抖动
// 就会队头阻塞：旧帧的碎块卡在队列里，新帧排后面 —— 用户看到的画面会越拖
// 越旧、越拖越卡（这正是远控最难受的体验）。所以帧通道用
// unordered + maxRetransmits:0，丢片就让这一帧作废：
//   · 收到不完整帧 → 直接丢弃（不显示半张撕开的图）；
//   · 收到更新的 seq → 立刻丢掉手上没拼完的旧帧。
// 控制通道（键鼠指令）仍然是可靠有序的 —— 少点一下比画面旧一帧严重得多。
//
// 这个文件是**纯 Dart**（不碰 dart:ffi / Flutter），所以能脱离真机单测：
// 乱序、丢片、跨帧交错、重复片、越界片都要有明确行为，见
// test/remote_frame_stream_test.dart。
import 'dart:typed_data';

/// 承载画面的 DataChannel 名。
///
/// 🔴 两端都必须按 label 区分通道：被控端建了两条（control / frames），
///    接收侧如果"来一条就当成控制通道"，后到的那条会把 `_dc` 覆盖掉 ——
///    表现是"鼠标键盘全部失灵"，而画面却是好的（正好把一个严重问题
///    伪装成一个不严重的问题）。
const String kRemoteFrameChannelLabel = 'frames';

/// 每片携带的负载上限（字节）。见文件头"为什么要分片"。
const int kRemoteFrameChunk = 16 * 1024;

/// 协议版本。放报文里而不是靠"猜"，将来换编码格式时收发两端能各判各的。
const int kRemoteFrameVer = 1;

/// 报文头长度：ver(1) + flags(1) + seq(4) + idx(2) + total(2) + w(2) + h(2)
const int kRemoteFrameHeader = 14;

/// 一帧的最大分片数上限（纯防御：头部是网络来的，不能信）。
/// 16KB x 4096 = 64MB，远超任何合理单帧，只用来挡住畸形 total。
const int _kMaxChunks = 4096;

/// 把一帧 JPEG 切成可直接 send 的二进制报文列表。
///
/// [seq] 单调递增的帧序号；[width]/[height] 是这一帧的像素尺寸 ——
/// 头里带上它，手机端就不需要另开一条消息同步尺寸，也天然免疫"尺寸消息
/// 丢了导致后续帧比例全错"这种问题。
List<Uint8List> packRemoteFrame({
  required int seq,
  required int width,
  required int height,
  required Uint8List jpeg,
  int chunk = kRemoteFrameChunk,
}) {
  final total = (jpeg.lengthInBytes + chunk - 1) ~/ chunk;
  final out = <Uint8List>[];
  for (var i = 0; i < total; i++) {
    final start = i * chunk;
    var end = start + chunk;
    if (end > jpeg.lengthInBytes) end = jpeg.lengthInBytes;
    final payload = end - start;
    final msg = Uint8List(kRemoteFrameHeader + payload);
    final bd = ByteData.view(msg.buffer);
    msg[0] = kRemoteFrameVer;
    msg[1] = 0; // flags（预留）
    bd.setUint32(2, seq & 0xFFFFFFFF);
    bd.setUint16(6, i);
    bd.setUint16(8, total);
    bd.setUint16(10, width & 0xFFFF);
    bd.setUint16(12, height & 0xFFFF);
    msg.setRange(kRemoteFrameHeader, kRemoteFrameHeader + payload, jpeg, start);
    out.add(msg);
  }
  return out;
}

/// 一个完整帧（重组完成）。
class RemoteFrame {
  const RemoteFrame({
    required this.seq,
    required this.width,
    required this.height,
    required this.jpeg,
  });

  final int seq;
  final int width;
  final int height;
  final Uint8List jpeg;
}

/// 分片重组器。**每个会话一个实例**，会话结束要 [reset]。
class RemoteFrameAssembler {
  int _seq = -1; // -1 = 还没收到任何帧
  List<Uint8List?> _parts = const [];
  int _got = 0;
  int _total = 0;
  int _w = 0;
  int _h = 0;
  bool _done = false;

  /// 拼好的完整帧数（诊断用）。
  int completed = 0;

  /// 因缺片 / 乱序被丢掉的帧数（诊断用）。
  int dropped = 0;

  /// 最近一帧的尺寸；还没成功拼出过帧时为 null。
  int? get width => _w > 0 ? _w : null;
  int? get height => _h > 0 ? _h : null;

  /// 喂一片。拼齐了返回整帧，否则返回 null。
  ///
  /// 输入是**网络来的字节**，任何字段都可能是垃圾 —— 一律先校验再信。
  RemoteFrame? feed(Uint8List msg) {
    if (msg.lengthInBytes < kRemoteFrameHeader) return null;
    if (msg[0] != kRemoteFrameVer) return null; // 别的版本，丢弃不崩

    final bd = ByteData.sublistView(msg);
    final seq = bd.getUint32(2);
    final idx = bd.getUint16(6);
    final total = bd.getUint16(8);
    final w = bd.getUint16(10);
    final h = bd.getUint16(12);

    if (total == 0 || total > _kMaxChunks) return null;
    if (idx >= total) return null;
    if (w == 0 || h == 0) return null;

    if (_seq < 0 || seq != _seq) {
      // 新帧序号：手上没拼完的那帧已经过时了（画面要最新，不要完整），丢掉。
      if (_seq >= 0 && !_done) dropped++;
      if (!_isNewer(seq, _seq)) {
        // 比手上这帧更旧的残片 —— 迟到的东西，直接无视，
        // 否则它会把已经切到新 seq 的重组状态又拽回去。
        return null;
      }
      _seq = seq;
      _total = total;
      _parts = List<Uint8List?>.filled(total, null);
      _got = 0;
      _w = w;
      _h = h;
      _done = false;
    }

    if (_done) return null; // 这一帧已经交出去了，后面的重复片无视
    if (total != _total) return null; // 同一 seq 的分片数不一致 = 畸形
    if (_parts[idx] != null) return null; // 重复片
    _parts[idx] = Uint8List.sublistView(msg, kRemoteFrameHeader);
    _got++;

    if (_got < _total) return null;

    // 拼齐
    var size = 0;
    for (final p in _parts) {
      size += p!.lengthInBytes;
    }
    final out = Uint8List(size);
    var off = 0;
    for (final p in _parts) {
      out.setRange(off, off + p!.lengthInBytes, p);
      off += p.lengthInBytes;
    }
    _done = true;
    completed++;
    return RemoteFrame(seq: seq, width: _w, height: _h, jpeg: out);
  }

  /// a 是否比 b 更新（seq 是 u32，会回绕；差值取模比较才是对的）。
  static bool _isNewer(int a, int b) {
    if (b < 0) return true;
    final d = (a - b) & 0xFFFFFFFF;
    return d != 0 && d < 0x80000000;
  }

  void reset() {
    _seq = -1;
    _parts = const [];
    _got = 0;
    _total = 0;
    _w = 0;
    _h = 0;
    _done = false;
    completed = 0;
    dropped = 0;
  }
}
