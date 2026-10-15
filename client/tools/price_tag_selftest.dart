// 价签的纯逻辑自测（包外裸脚本，本机可跑；正式判据仍是 CI 上的 flutter test）。
//
// ── 为什么单独有一份 ──────────────────────────────────────────
// price_tag 这套（排版 + 模板 + GBK）**零 Flutter 依赖**，所以它能在这台
// 派生不了 Dart 子进程的机器上直接跑。而"等 CI 跑 flutter test 才知道改坏了"
// 的代价太大：价签的字节错了现场表现就是一卷废纸，排查成本极高。
//
// 这里覆盖的是**最容易悄悄坏掉**的那几条：指令字、截断上限、空值跳过、状态复位。
import '../lib/core/gbk.dart';
import '../lib/core/price_tag.dart';
import '../lib/core/price_tag_template.dart';

int _fail = 0;
int _pass = 0;

void ck(String name, bool ok, [String why = '']) {
  if (ok) {
    _pass++;
    print('  ✓ $name');
  } else {
    _fail++;
    print('  ✗ $name${why.isEmpty ? '' : '  —— $why'}');
  }
}

/// 逐字节查子序列（List.contains 不做子序列匹配）。
bool hasSeq(List<int> hay, List<int> needle) {
  for (var i = 0; i + needle.length <= hay.length; i++) {
    var m = true;
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) {
        m = false;
        break;
      }
    }
    if (m) return true;
  }
  return false;
}

void main() {
  print('═══ 价签排版与模板 ═══');

  final item = PriceTagItem(
    barcode: '6901234567890',
    name: '有机鸡蛋',
    spec: '净重500g',
    price: 9.9,
    memberPrice: 8.8,
    originPrice: 12.0,
    unit: '盒',
  );

  // ── 指令字 ──
  print('── 指令字 ──');
  ck('打印区宽度用大写 GS W(0x57)，不是小写 GS w',
      PriceTagPrinter().setWidth(464)[1] == 0x57);
  ck('条码宽度用小写 GS w(0x77) 且单参数',
      PriceTagPrinter().barcodeWidth(3).length == 3 &&
          PriceTagPrinter().barcodeWidth(3)[1] == 0x77);
  ck('条码宽度钳在 2~6',
      PriceTagPrinter().barcodeWidth(1).last == 2 &&
          PriceTagPrinter().barcodeWidth(99).last == 6);
  ck('放大 x 在低 4 位、y 在高 4 位',
      PriceTagPrinter().scale(x: 2, y: 3).last == 0x21 &&
          PriceTagPrinter().scale(x: 3, y: 2).last == 0x12);
  ck('QR 指令是 GS ( k 五步齐全',
      hasSeq(PriceTagPrinter().qrcode('ABC'), const <int>[0x1D, 0x28, 0x6B]));

  // ── 截断 ──
  print('── 截断 ──');
  // 🔴 这串是 20 个字：必须**长到会被截断**才测得到截断。
  //    用短串的话两个分支都原样返回，"截断上限算错了"这条根本不会红
  //    （2026-10-16 就是被这个骗过一次：串只有 12 字，1 倍本来就放得下）。
  const long = '有机鸡蛋很好吃真的很好吃再来一份打包带走';
  final a = PriceTagPrinter.clipToWidth(long, 1, 400);
  final b = PriceTagPrinter.clipToWidth(long, 2, 400);
  // 400 点 ÷ 12 = 33 个西文位 → 1 倍放 16 个汉字，2 倍放 8 个
  ck('1 倍截断到 16 个汉字', a.length == 16, '实际 ${a.length}');
  ck('2 倍截断到 8 个汉字（截断跟着放大倍数走）', b.length == 8, '实际 ${b.length}');
  ck('截断后仍是原串的前缀（不能是中间抠一段）', long.startsWith(a) && long.startsWith(b));

  // ── 空值整行跳过 ──
  print('── 空值跳过 ──');
  const memEl = TagElement(kind: TagElementKind.text, field: TagField.memberPrice);
  final memTpl = PriceTagTemplate(
      id: 'x', name: 'x', widthMm: 50, heightMm: 30, elements: const [memEl]);
  final memP = PriceTagPrinter(label: LabelSize('x', 50));
  final plain = PriceTagItem(barcode: '6901234567890', name: '有机鸡蛋', price: 9.9);
  ck('没有会员价 → 整行不印（不印「会员 ￥0.00」）',
      memP.tagBytes(memTpl, plain).isEmpty);
  ck('有会员价 → 印出来',
      Gbk.decode(memP.tagBytes(memTpl, item)).contains('会员'));

  const orgEl = TagElement(kind: TagElementKind.text, field: TagField.originPrice);
  final orgTpl = PriceTagTemplate(
      id: 'y', name: 'y', widthMm: 50, heightMm: 30, elements: const [orgEl]);
  ck('原价 == 售价 → 整行不印',
      memP.tagBytes(orgTpl, const PriceTagItem(
              barcode: '1', name: 'a', price: 9.9, originPrice: 9.9))
          .isEmpty);
  ck('原价 > 售价 → 印出来',
      Gbk.decode(memP.tagBytes(orgTpl, item)).contains('原价'));

  // ── 状态复位 ──
  print('── 状态复位 ──');
  const hot = TagElement(
    kind: TagElementKind.text,
    field: TagField.price,
    bold: true,
    reverse: true,
    underline: true,
  );
  final hotTpl = PriceTagTemplate(
      id: 'z', name: 'z', widthMm: 50, heightMm: 30, elements: const [hot]);
  final hotBytes = memP.tagBytes(hotTpl, item);
  ck('加粗开了也关了',
      hasSeq(hotBytes, const <int>[0x1B, 0x45, 0x01]) &&
          hasSeq(hotBytes, const <int>[0x1B, 0x45, 0x00]));
  ck('反白开了也关了',
      hasSeq(hotBytes, const <int>[0x1D, 0x42, 0x01]) &&
          hasSeq(hotBytes, const <int>[0x1D, 0x42, 0x00]));
  ck('下划线开了也关了',
      hasSeq(hotBytes, const <int>[0x1B, 0x2D, 0x01]) &&
          hasSeq(hotBytes, const <int>[0x1B, 0x2D, 0x00]));
  const bcEl = TagElement(
      kind: TagElementKind.barcode, barcodeHeight: 160, hri: false);
  final bcTpl = PriceTagTemplate(
      id: 'w', name: 'w', widthMm: 50, heightMm: 30, elements: const [bcEl]);
  final bcBytes = memP.tagBytes(bcTpl, item);
  ck('条码高度设了也复位了',
      hasSeq(bcBytes, const <int>[0x1D, 0x68, 160]) &&
          hasSeq(bcBytes, const <int>[0x1D, 0x68, 80]));
  ck('HRI 关了也复位了', hasSeq(bcBytes, const <int>[0x1D, 0x48, 0x00]));

  // ── 内置模板 ──
  print('── 内置模板 ──');
  ck('内置模板共 6 套', kBuiltinTagTemplates.length == 6);
  final ids = <String>{};
  var allOk = true;
  for (final t in kBuiltinTagTemplates) {
    if (!ids.add(t.id)) allOk = false;
    final p = PriceTagPrinter(label: LabelSize(t.name, t.widthMm));
    final s = Gbk.decode(p.tagBytes(t, item));
    if (!s.contains('￥') || !s.contains('6901234567890')) allOk = false;
  }
  ck('6 套模板 id 不重复、每套都印得出价格+条码', allOk);

  var saveOk = true;
  for (final t in kBuiltinTagTemplates) {
    final back = PriceTagTemplate.fromJson(t.toJson());
    if (back == null) {
      saveOk = false;
      continue;
    }
    if (back.widthMm != t.widthMm) saveOk = false;
    if (back.elements.length != t.elements.length) saveOk = false;
    for (var i = 0; i < t.elements.length && i < back.elements.length; i++) {
      if (back.elements[i].kind != t.elements[i].kind) saveOk = false;
      if (back.elements[i].field != t.elements[i].field) saveOk = false;
      if (back.elements[i].reverse != t.elements[i].reverse) saveOk = false;
      if (back.elements[i].underline != t.elements[i].underline) saveOk = false;
      if (back.elements[i].hri != t.elements[i].hri) saveOk = false;
    }
  }
  ck('模板 JSON 往返不丢字段（反白/划线/条码数字都在）', saveOk);
  ck('空模板存不进库（存一个打不出东西的模板没意义）',
      PriceTagTemplate.fromJson(PriceTagTemplate(
                  id: 'e',
                  name: 'e',
                  widthMm: 50,
                  heightMm: 30,
                  elements: const <TagElement>[])
              .toJson()) ==
          null);

  // ── 批打印 ──
  print('── 批打印 ──');
  final t0 = kBuiltinTagTemplates.first;
  final p0 = PriceTagPrinter(label: LabelSize(t0.name, t0.widthMm));
  final out = p0.renderWithTemplate(<PriceTagItem>[item], t0);
  ck('开头是 init + GS W',
      out.length > 4 &&
          out[0] == 0x1B &&
          out[1] == 0x40 &&
          out[2] == 0x1D &&
          out[3] == 0x57);
  ck('结尾是切纸序列',
      hasSeq(out, const <int>[0x1B, 0x64, 0x03, 0x1D, 0x56, 0x42, 0x00]));
  final jumbo = kBuiltinTagTemplates.firstWhere((t) => t.id == 'builtin_jumbo');
  ck('75mm 模板按 75mm 设宽（纸宽跟着模板走）',
      hasSeq(PriceTagPrinter(label: LabelSize(jumbo.name, jumbo.widthMm))
              .renderWithTemplate(<PriceTagItem>[item], jumbo),
          const <int>[0x1D, 0x57, 0x58, 0x02]));

  // ── 顺手把标准价签打印出来的内容打出来给人看（肉眼判据）──
  print('── 标准价签（解码后）──');
  for (final t in kBuiltinTagTemplates) {
    final pp = PriceTagPrinter(label: LabelSize(t.name, t.widthMm));
    final s = Gbk.decode(pp.tagBytes(t, item));
    print('  [${t.name}] ${s.replaceAll('\n', ' ⏎ ')}');
  }

  print('');
  print('通过 $_pass 项，失败 $_fail 项');
  if (_fail > 0) {
    print('❌ 有失败项');
    // 包外裸脚本：用 exitCode 而不是 exit()，后者要引 dart:io
    throw StateError('price_tag_selftest failed: $_fail');
  }
  print('✓ 全部通过');
}
