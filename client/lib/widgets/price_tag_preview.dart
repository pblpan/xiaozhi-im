import 'dart:math' as math;

import 'package:barcode_widget/barcode_widget.dart';
import 'package:flutter/material.dart';
import 'package:xiaozhi_im_client/core/price_tag.dart';
import 'package:xiaozhi_im_client/core/price_tag_template.dart';

/// 价签模板的**图形预览**：画的就是那张纸，不是一串文本。
///
/// ─────────────────────────────────────────────────────────────
/// 为什么必须画出来
/// ─────────────────────────────────────────────────────────────
/// 旧预览是一段等宽文本：
///     ￥12.90  康师傅红烧牛肉面
///     桶装 105g
///     6920202888888
/// 它**回答不了**用户真正要问的三件事：字会不会挤出纸边？价格够不够大？
/// 促销那个黑底块长什么样？而这三件事恰恰是"打废一卷纸"的全部原因。
///
/// 所以这里按纸张的**真实比例**画：50×30 的纸在屏幕上就是 5:3 的一张卡，
/// 每个元素按它的放大倍数占到真实高度。用户在手机上看到的就是纸上那张。
///
/// ─────────────────────────────────────────────────────────────
/// 刻意不做的事
/// ─────────────────────────────────────────────────────────────
/// 二维码画的是示意图形（不含真实编码）—— 价签模板默认不带二维码，
/// 真要用的时候再接 qr 包。条码则是 Code128 真编码（见 _BarcodeStrip）。
class PriceTagPreview extends StatelessWidget {
  const PriceTagPreview({
    super.key,
    required this.template,
    required this.item,
    this.dateText = '',
    this.seq = 1,
    this.maxPxPerMm = 4.0,
  });

  final PriceTagTemplate template;
  final PriceTagItem item;

  /// 打印日期文案（模板里有"日期"元素时才出现）。
  final String dateText;
  final int seq;

  /// 每毫米最多画几个像素。手机上给 4 刚好让 75mm 的纸铺满屏宽。
  final double maxPxPerMm;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        // 纸宽铺满可用宽度（有上限，免得超宽屏上画成一张巨图）
        final px = box.maxWidth <= 0
            ? 3.0
            : (box.maxWidth / template.widthMm).clamp(1.2, maxPxPerMm);
        return Center(
          child: Container(
            width: template.widthMm * px,
            height: template.heightMm * px,
            decoration: BoxDecoration(
              // 🔴 恒为白纸：热敏纸就是白的，不跟深色主题走。
              //    深色主题下把"纸"画成黑的，预览就完全失去意义 ——
              //    用户要看的是"纸上长什么样"，不是"这个 App 长什么样"。
              color: Colors.white,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: const Color(0xFFBDBDBD)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.18),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: _paper(px),
            ),
          ),
        );
      },
    );
  }

  Widget _paper(double px) {
    final rows = <Widget>[];
    for (final e in template.elements) {
      final w = _element(e, px);
      if (w != null) rows.add(w);
    }
    // 内容比纸高时：直接裁掉下面溢出的部分（ClipRRect 已经在裁了），
    // 但要在视觉上让它"顶天立地"—— 从上往下排，跟打印机走纸方向一致
    return Padding(
      padding: EdgeInsets.all(px * 1.2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: rows,
      ),
    );
  }

  Widget? _element(TagElement e, double px) {
    if (e.kind == TagElementKind.line) {
      // '_' 字符在字形里是贴底的，所以线画在行的底部
      return Container(
        height: px * 3,
        alignment: Alignment.bottomCenter,
        child: Container(height: math.max(1.0, px * 0.35), color: Colors.black),
      );
    }

    if (e.kind == TagElementKind.barcode) {
      if (item.barcode.isEmpty) return null;
      final h = (e.barcodeHeight / 8.0) * px; // 点 → mm → px
      // 条码横向铺满纸宽（扣掉 _paper 的左右 padding）
      final w = template.widthMm * px - px * 2.4;
      return Padding(
        padding: EdgeInsets.symmetric(vertical: px * 0.4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _BarcodeStrip(code: item.barcode, height: h, width: w),
            // HRI：条码底下那串数字。关掉时不占位 ——
            // 预览和打印必须占一样的位置，否则"预览刚好、打出来多一行"
            if (e.hri)
              Text(
                item.barcode,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: px * 2.2,
                  height: 1.1,
                  color: Colors.black,
                  letterSpacing: 1.5,
                ),
              ),
          ],
        ),
      );
    }

    if (e.kind == TagElementKind.qrcode) {
      if (item.barcode.isEmpty) return null;
      final side = template.widthMm * px * 0.45;
      return Padding(
        padding: EdgeInsets.symmetric(vertical: px * 0.4),
        child: Center(
          child: CustomPaint(
            size: Size(side, side),
            painter: _QrPainter(item.barcode),
          ),
        ),
      );
    }

    // ── text ──
    final s = PriceTagPrinter.tagFieldText(
      e,
      item,
      scaleX: e.scaleX,
      widthDots: template.widthMm * 8,
      seq: seq,
      dateText: dateText,
    );
    if (s.isEmpty) return null; // 空值整行跳过，和打印端同一口径

    final fs = px * 2.6 * e.scaleY;
    final rowH = px * 3.0 * e.scaleY; // 12×24 点 = 3mm 高
    Widget text = Text(
      s,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      softWrap: false,
      textAlign: _textAlign(e.align),
      style: TextStyle(
        fontSize: fs,
        height: 1.0,
        fontWeight: e.bold ? FontWeight.w700 : FontWeight.w400,
        // 反白 = 黑底白字；下划线 = 给原价划一道
        decoration: e.underline ? TextDecoration.lineThrough : TextDecoration.none,
        color: e.reverse ? Colors.white : Colors.black,
        letterSpacing: e.scaleX > 1 ? 0.5 : 0,
      ),
    );

    if (e.reverse) {
      // 反白块要真的画成一块黑底，不然"黑底白字"看不出反差
      text = Container(
        color: Colors.black,
        padding: EdgeInsets.symmetric(horizontal: px * 0.8, vertical: px * 0.2),
        child: text,
      );
    }
    return SizedBox(
      height: rowH,
      child: Align(alignment: _boxAlign(e.align), child: text),
    );
  }

  static TextAlign _textAlign(TagAlign a) {
    switch (a) {
      case TagAlign.left:
        return TextAlign.left;
      case TagAlign.center:
        return TextAlign.center;
      case TagAlign.right:
        return TextAlign.right;
    }
  }

  static Alignment _boxAlign(TagAlign a) {
    switch (a) {
      case TagAlign.left:
        return Alignment.centerLeft;
      case TagAlign.center:
        return Alignment.center;
      case TagAlign.right:
        return Alignment.centerRight;
    }
  }
}

/// 真条码：Code128（和打印机发的是同一个码制 `GS k m=73`）。
///
/// 以前这里画的是"示意条"（按码值种子随机宽度）——看着像条码，
/// 实际扫不出来，也和对打印输出对不上。龙哥 2026-10-16 要求
/// "预览里面条形码要显示真实的条形码"，于是换成 Code128 真编码。
///
/// 🔴 Code128 只能编可打印 ASCII（32~126）。手输了中文/控制字符时
///    打印机同样发不出这个码 —— 预览老老实实显示文本，
///    不画假条、也不让整个预览崩掉。
class _BarcodeStrip extends StatelessWidget {
  const _BarcodeStrip({
    required this.code,
    required this.height,
    required this.width,
  });

  final String code;
  final double height;
  final double width;

  @override
  Widget build(BuildContext context) {
    final printable = code.codeUnits.every((u) => u >= 32 && u <= 126);
    if (!printable) {
      return SizedBox(
        width: width,
        height: height,
        child: Center(
          child: Text(
            code,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: height * 0.6, color: Colors.black),
          ),
        ),
      );
    }
    return SizedBox(
      width: width,
      height: height,
      child: BarcodeWidget(
        barcode: Barcode.code128(),
        data: code,
        drawText: false,
        color: Colors.black,
        padding: EdgeInsets.zero,
      ),
    );
  }
}

/// 二维码示意：三个定位角 + 数据点，看着是二维码就行（不含真实编码）。
class _QrPainter extends CustomPainter {
  _QrPainter(this.text);

  final String text;

  @override
  void paint(Canvas canvas, Size size) {
    var seed = 7;
    for (final u in text.codeUnits) {
      seed = (seed * 17 + u) & 0x7FFFFFFF;
    }
    final rnd = math.Random(seed);
    const n = 21;
    final cell = size.width / n;
    final dark = Paint()..color = Colors.black;

    void finder(double ox, double oy) {
      canvas.drawRect(Rect.fromLTWH(ox, oy, cell * 7, cell * 7), dark);
      canvas.drawRect(
        Rect.fromLTWH(ox + cell, oy + cell, cell * 5, cell * 5),
        Paint()..color = Colors.white,
      );
      canvas.drawRect(Rect.fromLTWH(ox + cell * 2, oy + cell * 2, cell * 3, cell * 3), dark);
    }

    canvas.drawColor(Colors.white, BlendMode.srcOver);
    for (var y = 0; y < n; y++) {
      for (var x = 0; x < n; x++) {
        final inFinder = (x < 8 && y < 8) || (x > n - 9 && y < 8) || (x < 8 && y > n - 9);
        if (inFinder) continue;
        if (rnd.nextBool()) {
          canvas.drawRect(Rect.fromLTWH(x * cell, y * cell, cell, cell), dark);
        }
      }
    }
    finder(0, 0);
    finder((n - 7) * cell, 0);
    finder(0, (n - 7) * cell);
  }

  @override
  bool shouldRepaint(covariant _QrPainter old) => old.text != text;
}
