import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:xiaozhi_im_client/core/clipboard_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:xiaozhi_im_client/core/theme.dart';
import 'package:xiaozhi_im_client/core/win_screen.dart';

/// 截图编辑器（Windows）：框选 → 标注（画笔/马赛克/矩形/箭头/文字）→ 发送。
///
/// 流程：
///   ① 聊天页点「截图」→ WinScreen.captureScreen() 截整个虚拟屏幕；
///   ② 本页以「框选模式」打开：整个屏幕的截图铺在窗口里，拖一块矩形选区
///      （窗口外的屏幕内容也在图里，选它照样有效 —— 效果等同微信截图）；
///   ③ 选完可「直接发送」，或进「标注模式」涂画后再发；
///   ④ 「复制文字」随时可用：把当前选区交给系统离线 OCR，弹窗展示 + 一键复制。
///
/// 【坐标系】所有绘制（选区/笔迹）都以**图片物理像素**为准，组件坐标只在
/// 手势入口处换算一次。这样导出就是"原图尺寸的 canvas → png"，不会因为
/// 窗口缩放/预览比例引入偏移。
class ScreenshotEditorPage extends StatefulWidget {
  final String imagePath;

  const ScreenshotEditorPage({super.key, required this.imagePath});

  @override
  State<ScreenshotEditorPage> createState() => _ScreenshotEditorPageState();
}

class _ScreenshotEditorPageState extends State<ScreenshotEditorPage> {
  ui.Image? _img; // 当前底图（框选阶段=整屏截图；标注阶段=裁剪后的选区）
  ui.Image? _mosaic; // 马赛克底图（原图打码版，马赛克笔刷"露出"的就是它）
  bool _loading = true;
  bool _annotating = false; // false=框选模式，true=标注模式
  bool _ocrBusy = false;

  // ── 框选 ──
  Offset? _dragFrom; // 拖动起点（组件坐标）
  Rect? _sel; // 选区（组件坐标）

  // ── 标注 ──
  final List<_Stroke> _strokes = [];
  String _tool = 'pen';
  Color _color = const Color(0xFFE53935);
  _Stroke? _drawing; // 正在画的这一笔

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final bytes = await File(widget.imagePath).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    if (!mounted) return;
    setState(() {
      _img = frame.image;
      _loading = false;
    });
    _buildMosaic();
  }

  /// 预生成马赛克底图：缩到 1/12 再拉回原尺寸（像素化）。
  /// 马赛克笔刷的原理是"用笔迹路径当蒙版，把这层糊图露出来"。
  Future<void> _buildMosaic() async {
    final src = _img;
    if (src == null) return;
    final w = src.width, h = src.height;
    final sw = (w / 12).round().clamp(1, 4096);
    final sh = (h / 12).round().clamp(1, 4096);
    final rec = ui.PictureRecorder();
    Canvas(rec)
      ..drawImageRect(
          src,
          Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
          Rect.fromLTWH(0, 0, sw.toDouble(), sh.toDouble()),
          Paint()..filterQuality = FilterQuality.low);
    final small = await rec.endRecording().toImage(sw, sh);
    final rec2 = ui.PictureRecorder();
    Canvas(rec2)
      ..drawImageRect(
          small,
          Rect.fromLTWH(0, 0, sw.toDouble(), sh.toDouble()),
          Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
          Paint()..filterQuality = FilterQuality.none);
    final m = await rec2.endRecording().toImage(w, h);
    if (mounted) setState(() => _mosaic = m);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      // ESC 取消（对标 QQ 截图）：任何时候按 Esc 都退出，不拦其他键
      body: Focus(
        autofocus: true,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.escape) {
            Navigator.pop(context);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: _loading
            ? const Center(
                child: SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70)))
            : LayoutBuilder(builder: (context, box) {
                final disp = _displayRect(box.biggest);
                return Stack(
                  children: [
                    Positioned.fromRect(
                      rect: disp,
                      child: RawImage(image: _img, fit: BoxFit.fill),
                    ),
                    Positioned.fromRect(
                      rect: disp,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapUp: _tool == 'text' && _annotating
                            ? (d) => _placeText(d.localPosition, disp)
                            : null,
                        onPanStart: _tool == 'text' ? null : (d) => _onPanStart(d.localPosition, disp),
                        onPanUpdate: _tool == 'text' ? null : (d) => _onPanUpdate(d.localPosition, disp),
                        onPanEnd: _tool == 'text' ? null : (_) => _onPanEnd(),
                        child: CustomPaint(
                          painter: _EditorPainter(
                            img: _img,
                            sel: _annotating ? null : _sel,
                            selDragging: _dragFrom != null && !_annotating,
                            dragFrom: _dragFrom,
                            strokes: _annotating ? _strokes : const [],
                            drawing: _annotating ? _drawing : null,
                            mosaic: _mosaic,
                            dispRect: disp,
                          ),
                          child: const SizedBox.expand(),
                        ),
                      ),
                    ),
                    // 框选时跟随显示选区尺寸（QQ 截图的手感）
                    if (!_annotating && _sel != null)
                      Positioned(
                        left: (_sel!.right + 6)
                            .clamp(4.0, (box.maxWidth - 90).clamp(4.0, double.infinity)),
                        top: (_sel!.bottom + 4)
                            .clamp(4.0, (box.maxHeight - 30).clamp(4.0, double.infinity)),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.black87,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            '${_sel!.width.toInt()} × ${_sel!.height.toInt()}',
                            style: const TextStyle(
                                color: Colors.white, fontSize: 11.5),
                          ),
                        ),
                      ),
                    Positioned(
                      left: 0, right: 0, bottom: 0,
                      child: _toolbar(disp),
                    ),
                    if (_ocrBusy)
                      Positioned.fill(
                        child: Container(
                          color: Colors.black38,
                          child: const Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                CircularProgressIndicator(color: Colors.white70),
                                SizedBox(height: 10),
                                Text('正在识别文字…',
                                    style: TextStyle(color: Colors.white70, fontSize: 13)),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              }),
      ),
    );
  }

  /// 图片在窗口里的显示区（contain 居中）。所有坐标换算都以它为基准。
  Rect _displayRect(Size window) {
    final img = _img!;
    final scale = (window.width / img.width).clamp(0.0, window.height / img.height);
    final w = img.width * scale, h = img.height * scale;
    return Rect.fromLTWH((window.width - w) / 2, (window.height - h) / 2, w, h);
  }

  /// 组件坐标 → 图片物理像素坐标
  Offset _toImage(Offset pos, Rect disp) => Offset(
        (pos.dx - disp.left) / disp.width * _img!.width,
        (pos.dy - disp.top) / disp.height * _img!.height,
      );

  // ── 手势 ──

  void _onPanStart(Offset pos, Rect disp) {
    if (!_annotating) {
      setState(() => _dragFrom = pos);
      return;
    }
    final ip = _toImage(pos, disp);
    setState(() => _drawing = _Stroke(
          tool: _tool,
          color: _color,
          points: [ip, ip],
          width: _tool == 'mosaic' ? 26 : 4.5,
        ));
  }

  void _onPanUpdate(Offset pos, Rect disp) {
    if (!_annotating) {
      final f = _dragFrom;
      if (f == null) return;
      setState(() => _sel = Rect.fromPoints(f, pos));
      return;
    }
    final d = _drawing;
    if (d == null) return;
    // 画笔/马赛克密集采点；矩形/箭头只有首尾两点
    if (d.tool == 'pen' || d.tool == 'mosaic') d.points.add(_toImage(pos, disp));
    else d.points[1] = _toImage(pos, disp);
    setState(() {});
  }

  void _onPanEnd() {
    if (!_annotating) {
      setState(() => _dragFrom = null);
      return;
    }
    final d = _drawing;
    if (d == null) return;
    _strokes.add(d);
    _drawing = null;
    setState(() {});
  }

  /// 文字工具：点一下 → 输入 → 落在点击处
  Future<void> _placeText(Offset pos, Rect disp) async {
    final ctl = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('标注文字'),
        content: TextField(controller: ctl, autofocus: true, maxLength: 60),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, ctl.text.trim()), child: const Text('确定')),
        ],
      ),
    );
    if (text == null || text.isEmpty || !mounted) return;
    setState(() => _strokes.add(_Stroke(
          tool: 'text',
          color: _color,
          points: [_toImage(pos, disp)],
          text: text,
          width: 26,
        )));
  }

  // ── 工具条 ──

  Widget _toolbar(Rect disp) {
    if (!_annotating) {
      return Container(
        color: Colors.black54,
        padding: EdgeInsets.fromLTRB(12, 8, 12, 8 + MediaQuery.of(context).padding.bottom),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          reverse: true,
          child: Row(children: [
            _tBtn('取消', () => Navigator.pop(context)),
            const SizedBox(width: 6),
            _tBtn('重选', () => setState(() => _sel = null)),
            const SizedBox(width: 6),
            _tBtn('复制文字', _ocrBusy ? null : () => _ocrSelection(disp)),
            const SizedBox(width: 6),
            _tBtn('标注 →', _sel == null || (_sel?.width ?? 0) < 6
                ? null
                : () => _enterAnnotate(disp)),
            const SizedBox(width: 6),
            _tBtn('保存', _sel == null || (_sel?.width ?? 0) < 6 ? null : () => _saveToFile(crop: true, disp: disp)),
            const SizedBox(width: 6),
            _tBtn('复制', _sel == null || (_sel?.width ?? 0) < 6 ? null : () => _copyToClipboard(crop: true, disp: disp)),
            const SizedBox(width: 6),
            _tBtn('发送', _sel == null || (_sel?.width ?? 0) < 6
                ? null
                : () => _finish(crop: true, disp: disp), primary: true),
          ]),
        ),
      );
    }
    return Container(
      color: Colors.black54,
      padding: EdgeInsets.fromLTRB(12, 8, 12, 8 + MediaQuery.of(context).padding.bottom),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(children: [
          _toolBtn(Icons.edit_rounded, '画笔', 'pen'),
          _toolBtn(Icons.blur_on_rounded, '马赛克', 'mosaic'),
          _toolBtn(Icons.crop_square_rounded, '矩形', 'rect'),
          _toolBtn(Icons.arrow_outward_rounded, '箭头', 'arrow'),
          _toolBtn(Icons.text_fields_rounded, '文字', 'text'),
          const SizedBox(width: 10),
          for (final c in const [
            Color(0xFFE53935), Color(0xFF1E88E5), Color(0xFFFDD835),
            Color(0xFFFFFFFF), Color(0xFF212121),
          ])
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: InkWell(
                onTap: () => setState(() => _color = c),
                customBorder: const CircleBorder(),
                child: Container(
                  width: 24, height: 24,
                  decoration: BoxDecoration(
                    color: c,
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: _color == c ? Colors.white : Colors.white24,
                        width: _color == c ? 2.5 : 1),
                  ),
                ),
              ),
            ),
          const SizedBox(width: 10),
          _tBtn('撤销', _strokes.isEmpty ? null : () {
            setState(() => _strokes.removeLast());
          }),
          const SizedBox(width: 6),
          _tBtn('复制文字', _ocrBusy ? null : _ocrAnnotated),
          const SizedBox(width: 6),
          _tBtn('保存', () => _saveToFile(crop: false)),
          const SizedBox(width: 6),
          _tBtn('复制', () => _copyToClipboard(crop: false)),
          const SizedBox(width: 6),
          _tBtn('发送', () => _finish(crop: false), primary: true),
        ]),
      ),
    );
  }

  Widget _tBtn(String label, VoidCallback? onTap, {bool primary = false}) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: OutlinedButton(
          onPressed: onTap,
          style: OutlinedButton.styleFrom(
            foregroundColor: primary ? Colors.black : Colors.white,
            backgroundColor: primary ? Colors.amber : Colors.white10,
            side: const BorderSide(color: Colors.white24),
            minimumSize: const Size(0, 34),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            textStyle: const TextStyle(fontSize: 13),
          ),
          child: Text(label),
        ),
      );

  Widget _toolBtn(IconData icon, String label, String tool) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: InkWell(
          onTap: () => setState(() => _tool = tool),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
            decoration: BoxDecoration(
              color: _tool == tool ? Colors.white24 : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 16, color: Colors.white),
              const SizedBox(width: 4),
              Text(label, style: const TextStyle(color: Colors.white, fontSize: 12.5)),
            ]),
          ),
        ),
      );

  // ── 动作 ──

  /// 框选 → 标注模式：把选区裁成新的底图
  Future<void> _enterAnnotate(Rect disp) async {
    final sel = _sel!;
    final src = _img!;
    final sx = src.width / disp.width, sy = src.height / disp.height;
    final rec = ui.PictureRecorder();
    Canvas(rec).drawImageRect(
      src,
      Rect.fromLTWH((sel.left - disp.left) * sx, (sel.top - disp.top) * sy,
          sel.width * sx, sel.height * sy),
      Rect.fromLTWH(0, 0, sel.width * sx, sel.height * sy),
      Paint(),
    );
    final cropped = await rec.endRecording().toImage(
        (sel.width * sx).round().clamp(1, 8192), (sel.height * sy).round().clamp(1, 8192));
    setState(() {
      _img = cropped;
      _annotating = true;
      _sel = null;
      _strokes.clear();
      _tool = 'pen';
    });
    _buildMosaic();
  }

  /// 把当前画面（框选的选区 / 标注后的整图 + 全部笔迹）渲染成 PNG 文件。
  /// 发送 / 保存 / 复制三个动作共用这一个出口，保证"看到什么拿出去什么"。
  ///
  /// [crop] true=只导 [disp] 里的选区（框选模式）；false=导当前整图（标注模式）。
  /// 失败返回 null（调用方给 toast）。
  ///
  /// 🔴 修复（2026-10-15）：旧版「发送」在框选模式下直接导全屏截图，
  ///    crop 参数根本没实现 —— 用户框了半张图，发出去却是整个桌面。
  Future<File?> _exportPng({required bool crop, Rect? disp}) async {
    final img = _img;
    if (img == null) return null;
    try {
      var w = img.width, h = img.height;
      var srcRect = Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble());
      if (crop) {
        final sel = _sel;
        final d = disp;
        if (sel == null || sel.width < 6 || d == null) return null;
        // 选区是组件坐标，要按显示比换算回图片像素
        final sx = img.width / d.width, sy = img.height / d.height;
        w = (sel.width * sx).round().clamp(1, 8192);
        h = (sel.height * sy).round().clamp(1, 8192);
        srcRect = Rect.fromLTWH((sel.left - d.left) * sx,
            (sel.top - d.top) * sy, sel.width * sx, sel.height * sy);
      }
      final rec = ui.PictureRecorder();
      final c = ui.Canvas(rec, Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()));
      c.drawImageRect(img, srcRect, Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint());
      if (!crop) _paintStrokes(c);
      final out = await rec.endRecording().toImage(w, h);
      final bd = await out.toByteData(format: ui.ImageByteFormat.png);
      if (bd == null) return null;
      final dir = await getTemporaryDirectory();
      final f = File(p.join(
          dir.path, 'shot_${DateTime.now().millisecondsSinceEpoch}.png'));
      await f.writeAsBytes(bd.buffer.asUint8List());
      return f;
    } catch (e) {
      if (mounted) _toast('导出失败: $e');
      return null;
    }
  }

  /// 发送：导出后把文件交回聊天页（pop 返回值即 File）
  Future<void> _finish({required bool crop, Rect? disp}) async {
    final f = await _exportPng(crop: crop, disp: disp);
    if (f == null) return;
    if (!mounted) return;
    Navigator.pop(context, f);
  }

  /// 保存到本地（对标 QQ 截图的「保存」）：弹系统另存为对话框。
  /// file_picker 的 saveFile 直接把 bytes 写到用户选的位置，不用自己 copy。
  Future<void> _saveToFile({required bool crop, Rect? disp}) async {
    final f = await _exportPng(crop: crop, disp: disp);
    if (f == null) return;
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final suggested =
        '截图_${now.year}${two(now.month)}${two(now.day)}_${two(now.hour)}${two(now.minute)}${two(now.second)}.png';
    try {
      final uri = await FilePickerPlatform.instance.saveFile(
        dialogTitle: '保存截图',
        fileName: suggested,
        bytes: await f.readAsBytes(),
        mimeType: 'image/png',
      );
      if (uri == null) return; // 用户取消了保存
      _toast('已保存');
    } catch (e) {
      _toast('保存失败: $e');
    }
  }

  /// 复制到剪贴板（对标 QQ 截图的「复制」）：别处直接 Ctrl+V 能粘出去
  Future<void> _copyToClipboard({required bool crop, Rect? disp}) async {
    final f = await _exportPng(crop: crop, disp: disp);
    if (f == null) return;
    final ok = writeClipboardPng(await f.readAsBytes());
    _toast(ok ? '已复制到剪贴板' : '复制失败（剪贴板被其他程序占用，请重试）');
  }

  /// OCR 当前画面（标注模式=整张；框选模式=选区）
  Future<void> _ocrAnnotated() async {
    final img = _img;
    if (img == null) return;
    await _ocrRun(() async {
      final rec = ui.PictureRecorder();
      final c = Canvas(rec, Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()));
      c.drawImage(img, Offset.zero, Paint());
      _paintStrokes(c);
      final out = await rec.endRecording().toImage(img.width, img.height);
      return out.toByteData(format: ui.ImageByteFormat.png);
    });
  }

  Future<void> _ocrSelection(Rect disp) async {
    final sel = _sel;
    final src = _img;
    if (src == null) return;
    final hasSel = sel != null && sel.width >= 6;
    final sx = src.width / disp.width, sy = src.height / disp.height;
    final cw = hasSel ? (sel.width * sx).round().clamp(1, 8192) : src.width;
    final ch = hasSel ? (sel.height * sy).round().clamp(1, 8192) : src.height;
    await _ocrRun(() async {
      final rec = ui.PictureRecorder();
      final c = ui.Canvas(rec, Rect.fromLTWH(0, 0, cw.toDouble(), ch.toDouble()));
      if (hasSel) {
        c.drawImageRect(
          src,
          Rect.fromLTWH((sel.left - disp.left) * sx, (sel.top - disp.top) * sy,
              sel.width * sx, sel.height * sy),
          Rect.fromLTWH(0, 0, cw.toDouble(), ch.toDouble()),
          Paint(),
        );
      } else {
        c.drawImage(src, Offset.zero, Paint());
      }
      final out = await rec.endRecording().toImage(cw, ch);
      return out.toByteData(format: ui.ImageByteFormat.png);
    });
  }

  Future<void> _ocrRun(Future<ByteData?> Function() render) async {
    setState(() => _ocrBusy = true);
    try {
      final bd = await render();
      if (bd == null) throw '截图数据为空';
      final dir = await getTemporaryDirectory();
      final f = File(p.join(dir.path, 'ocr_${DateTime.now().millisecondsSinceEpoch}.png'));
      await f.writeAsBytes(bd.buffer.asUint8List());
      final text = await WinScreen.recognizeText(f.path);
      try { f.deleteSync(); } catch (_) { /* 临时文件删不掉就算了 */ }
      if (!mounted) return;
      if (text == null) {
        _toast('本机没有可用的 OCR 语言包（控制面板 → 区域 → 添加中文语言功能）');
        return;
      }
      final t = text.trim();
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.surface,
          title: const Text('识别结果'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: SelectableText(
                t.isEmpty ? '（没有识别到文字）' : t,
                style: const TextStyle(fontSize: 14, height: 1.5),
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
            FilledButton(
              onPressed: t.isEmpty ? null : () async {
                await Clipboard.setData(ClipboardData(text: t));
                if (ctx.mounted) Navigator.pop(ctx);
                _toast('已复制到剪贴板');
              },
              child: const Text('复制全部'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) _toast('识别失败：$e');
    } finally {
      if (mounted) setState(() => _ocrBusy = false);
    }
  }

  void _toast(String s) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(s), duration: const Duration(seconds: 2)));

  /// 把笔迹画到 canvas（图片像素坐标系）
  void _paintStrokes(ui.Canvas c) {
    for (final s in [..._strokes, if (_drawing != null) _drawing!]) {
      s.paint(c, _mosaic);
    }
  }
}

// ── 笔迹模型 ──

class _Stroke {
  final String tool; // pen | mosaic | rect | arrow | text
  final Color color;
  final List<Offset> points; // pen/mosaic 为轨迹；rect/arrow 为 [起点,终点]；text 为落点
  final String? text;
  final double width;

  _Stroke({required this.tool, required this.color, required this.points, this.text, this.width = 4.5});

  void paint(ui.Canvas c, ui.Image? mosaic) {
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    switch (tool) {
      case 'pen':
        if (points.length < 2) return;
        c.drawPath(_pathOf(points), p);
        return;
      case 'mosaic':
        final m = mosaic;
        if (m == null || points.length < 2) return;
        c.save();
        c.clipPath(_pathOf(points));
        c.drawImage(m, Offset.zero, Paint()..filterQuality = FilterQuality.none);
        c.restore();
        return;
      case 'rect':
        if (points.length < 2) return;
        c.drawRect(Rect.fromPoints(points.first, points.last), p);
        return;
      case 'arrow':
        if (points.length < 2) return;
        final a = points.first, b = points.last;
        c.drawLine(a, b, p);
        // 箭头头部：两条短线，张角 30°
        final dir = (b - a);
        if (dir.distance < 2) return;
        final unit = dir / dir.distance;
        const len = 18.0;
        final left = Offset(
            unit.dx * 0.866 - unit.dy * 0.5, unit.dy * 0.866 + unit.dx * 0.5);
        final right = Offset(
            unit.dx * 0.866 + unit.dy * 0.5, unit.dy * 0.866 - unit.dx * 0.5);
        c.drawLine(b, b - left * len, p);
        c.drawLine(b, b - right * len, p);
        return;
      case 'text':
        final t = text;
        if (t == null || t.isEmpty || points.isEmpty) return;
        final tp = TextPainter(
          text: TextSpan(
              text: t,
              style: TextStyle(
                  color: color, fontSize: width, fontWeight: FontWeight.w600)),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: 2000);
        tp.paint(c, points.first);
        return;
    }
  }

  ui.Path _pathOf(List<Offset> pts) {
    final path = ui.Path();
    if (pts.isEmpty) return path;
    path.moveTo(pts.first.dx, pts.first.dy);
    for (var i = 1; i < pts.length; i++) {
      path.lineTo(pts[i].dx, pts[i].dy);
    }
    return path;
  }
}

// ── 画布 ──

class _EditorPainter extends CustomPainter {
  final ui.Image? img;
  final Rect? sel; // 框选模式下的选区（组件坐标）
  final bool selDragging;
  final Offset? dragFrom;
  final List<_Stroke> strokes;
  final _Stroke? drawing;
  final ui.Image? mosaic;
  final Rect dispRect;

  _EditorPainter({
    required this.img,
    required this.sel,
    required this.selDragging,
    required this.dragFrom,
    required this.strokes,
    required this.drawing,
    required this.mosaic,
    required this.dispRect,
  });

  @override
  void paint(ui.Canvas canvas, Size size) {
    // 1. 选区遮罩（框选模式）：选区外压暗，边界白框
    final s = sel ??
        (selDragging && dragFrom != null ? Rect.fromPoints(dragFrom!, dragFrom!) : null);
    if (s != null) {
      canvas.save();
      // 用两个矩形拼出"外部区域"做 even-odd 填充
      final outer = Path()
        ..addRect(Rect.fromLTWH(0, 0, size.width, size.height))
        ..addRect(s)
        ..fillType = PathFillType.evenOdd;
      canvas.drawPath(outer, Paint()..color = Colors.black.withValues(alpha: 0.55));
      canvas.restore();
      canvas.drawRect(s, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.white);
      // 四角加粗短线（微信截图那种角标）
      const l = 16.0;
      final corner = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..color = Colors.white;
      void cornerLine(Offset a, Offset b) => canvas.drawLine(a, b, corner);
      cornerLine(s.topLeft, s.topLeft + Offset(l, 0));
      cornerLine(s.topLeft, s.topLeft + Offset(0, l));
      cornerLine(s.topRight, s.topRight + Offset(-l, 0));
      cornerLine(s.topRight, s.topRight + Offset(0, l));
      cornerLine(s.bottomLeft, s.bottomLeft + Offset(l, 0));
      cornerLine(s.bottomLeft, s.bottomLeft + Offset(0, -l));
      cornerLine(s.bottomRight, s.bottomRight + Offset(-l, 0));
      cornerLine(s.bottomRight, s.bottomRight + Offset(0, -l));
    }

    // 2. 笔迹（标注模式）：坐标系切到图片物理像素
    final im = img;
    if (im != null && (strokes.isNotEmpty || drawing != null)) {
      canvas.save();
      canvas.translate(dispRect.left, dispRect.top);
      canvas.scale(dispRect.width / im.width);
      for (final st in strokes) {
        st.paint(canvas, mosaic);
      }
      drawing?.paint(canvas, mosaic);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_EditorPainter old) => true;
}
