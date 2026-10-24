// 自研画面通道的渲染件：把 DataChannel 收到的 JPEG 帧贴到画布上。
//
// ─────────────────────────────────────────────────────────────
// 【为什么不直接用 Image.memory】
// ─────────────────────────────────────────────────────────────
// Image.memory 走的是 Flutter 的 ImageCache，而缓存 key 就是那个 Uint8List
// 对象本身。远程协助每秒换 8~13 帧、每帧都是一个全新的对象 —— 缓存条目
// 只增不减，解码后的位图全被留住，手机上几百兆内存就这么没了（而且是在
// 一个"正在看对方屏幕"的长时间会话里慢慢涨）。所以这里绕开 ImageCache：
// 自己 instantiateImageCodec 解成 ui.Image，上了新的就把上一张 dispose ——
// 内存里永远只有一两张图。
//
// ─────────────────────────────────────────────────────────────
// 【为什么要"代数"而不是来一帧解一帧】
// ─────────────────────────────────────────────────────────────
// 解码是异步的（几毫秒）。如果每来一帧就发一次解码，慢的那几次会**乱序
// 回来**，画面就会一帧新一帧旧地来回跳。所以：
//   · 同一时刻只允许一次解码在飞；
//   · 解码期间来的帧只记一个"有新帧"的标记，解完立刻用**当时最新**的那帧；
//   · 回来的结果代数和当前不一致就直接 dispose 丢掉。
// 结果是：解码永远追着最新的那帧跑，宁可跳帧也不倒放。
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

class RemoteFrameView extends StatefulWidget {
  const RemoteFrameView({
    super.key,
    required this.jpeg,
    this.fit = BoxFit.fill,
    this.filterQuality = FilterQuality.low,
    this.onDecode,
  });

  /// 最新一帧 JPEG。null 表示还没收到过（此时本件不画东西）。
  final ValueListenable<Uint8List?> jpeg;

  /// 每帧解码结果回调（true=解出来了 / false=Skia 解不开）。
  /// 黑屏排查用：**收到帧**和**解得开帧**是两件事，必须在 UI 上分得清。
  final void Function(bool ok)? onDecode;

  final BoxFit fit;

  /// 默认 low：帧率优先，而且缩放比例固定（画面矩形是按帧尺寸算的），
  /// 用 medium 只会白白多花 GPU 时间。
  final FilterQuality filterQuality;

  @override
  State<RemoteFrameView> createState() => _RemoteFrameViewState();
}

class _RemoteFrameViewState extends State<RemoteFrameView> {
  ui.Image? _img;
  int _gen = 0;
  bool _decoding = false;
  bool _dirty = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    widget.jpeg.addListener(_onFrame);
    _onFrame();
  }

  @override
  void didUpdateWidget(RemoteFrameView old) {
    super.didUpdateWidget(old);
    if (!identical(old.jpeg, widget.jpeg)) {
      old.jpeg.removeListener(_onFrame);
      widget.jpeg.addListener(_onFrame);
      _onFrame();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    widget.jpeg.removeListener(_onFrame);
    _img?.dispose();
    _img = null;
    super.dispose();
  }

  void _onFrame() {
    if (_disposed) return;
    final bytes = widget.jpeg.value;
    if (bytes == null) return;
    if (_decoding) {
      _dirty = true;
      return;
    }
    unawaited(_decode(bytes));
  }

  Future<void> _decode(Uint8List bytes) async {
    _decoding = true;
    final gen = ++_gen;
    try {
      final codec = await ui.instantiateImageCodec(bytes);
      final frame = await codec.getNextFrame();
      codec.dispose();
      if (_disposed || gen != _gen) {
        frame.image.dispose();
        return;
      }
      final old = _img;
      setState(() => _img = frame.image);
      old?.dispose();
      widget.onDecode?.call(true);
    } catch (_) {
      // 字节仍然是网络上来的，理论上被分片重组挡住了半张图，
      // 但真解不开也不该让 UI 崩 —— 下一帧马上就到。
      widget.onDecode?.call(false);
    } finally {
      _decoding = false;
      if (_dirty) {
        _dirty = false;
        _onFrame();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final img = _img;
    if (img == null) return const SizedBox.expand();
    return RawImage(
      image: img,
      fit: widget.fit,
      filterQuality: widget.filterQuality,
    );
  }
}
