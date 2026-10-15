import 'package:flutter/material.dart';
import 'package:xiaozhi_im_client/core/price_tag.dart';
import 'package:xiaozhi_im_client/core/price_tag_store.dart';
import 'package:xiaozhi_im_client/core/price_tag_template.dart';
import 'package:xiaozhi_im_client/core/theme.dart';
import 'package:xiaozhi_im_client/widgets/price_tag_preview.dart';

/// 示例商品 —— 预览用什么数据都不能是空的。
///
/// 用一个**真的像商品**的样本（有品名、有规格、有会员价、有原价），
/// 而不是「商品名 / 价格」这种占位符：只有当预览上真的写着
/// 「康师傅红烧牛肉面 ￥5.50」，用户才判断得出"字会不会挤出纸边"。
/// 空占位符的预览等于没预览。
const PriceTagItem _sample = PriceTagItem(
  barcode: '6920202888888',
  name: '康师傅红烧牛肉面',
  spec: '桶装 105g',
  price: 5.5,
  memberPrice: 4.9,
  originPrice: 6.5,
  unit: '桶',
);

/// 价签模板管理：看、选、另存、新建、编辑、删除。
///
/// ─────────────────────────────────────────────────────────────
/// 为什么每张都要画预览
/// ─────────────────────────────────────────────────────────────
/// 模板的本质是"这张纸上长什么样"。只列名字（「促销价签 50×30」）的话，
/// 用户要选出一副合适的还得先记住自己建过什么 —— 6 套以后就记不住了。
/// 所以列表里每一行都真的画一张缩略图，选的时候是**看着挑**不是**猜着挑**。
class PriceTagTemplatePage extends StatefulWidget {
  const PriceTagTemplatePage({super.key});

  @override
  State<PriceTagTemplatePage> createState() => _PriceTagTemplatePageState();
}

class _PriceTagTemplatePageState extends State<PriceTagTemplatePage> {
  List<PriceTagTemplate> _tpls = List<PriceTagTemplate>.from(kBuiltinTagTemplates);
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final all = await PriceTagStore.I.list();
    if (!mounted) return;
    setState(() {
      _tpls = all;
      _loading = false;
    });
  }

  Future<void> _open(PriceTagTemplate t) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(builder: (_) => _TemplateEditorPage(initial: t)),
    );
    await _load();
  }

  Future<void> _create() async {
    final t = PriceTagTemplate(
      id: newTemplateId(),
      name: '我的价签',
      widthMm: 50,
      heightMm: 30,
      elements: <TagElement>[
        const TagElement(kind: TagElementKind.text, field: TagField.name, scaleX: 2, scaleY: 2, bold: true),
        const TagElement(kind: TagElementKind.text, field: TagField.price, scaleX: 3, scaleY: 3, bold: true, align: TagAlign.right),
        const TagElement(kind: TagElementKind.barcode, align: TagAlign.center),
      ],
    );
    await _open(t);
  }

  Future<void> _delete(PriceTagTemplate t) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('删除模板'),
        content: Text('删掉「${t.name}」后就没了。用它打过的标签不受影响。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Text('删除', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await PriceTagStore.I.remove(t.id);
    await PriceTagStore.I.setLast(kDefaultTemplateId);
    if (!mounted) return;
    _toast('已删除');
    await _load();
  }

  void _toast(String s) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(s), duration: const Duration(seconds: 2)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('价签模板'),
        actions: [
          IconButton(
            tooltip: '新建模板',
            icon: const Icon(Icons.add_rounded),
            onPressed: _create,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
              itemCount: _tpls.length,
              separatorBuilder: (_, __) => const SizedBox(height: 12),
              itemBuilder: (c, i) => _Card(
                tpl: _tpls[i],
                onEdit: () => _open(_tpls[i]),
                onCopy: () async {
                  final copy = _tpls[i].copyWith(
                    id: newTemplateId(),
                    name: '${_tpls[i].name} 副本',
                    builtin: false,
                  );
                  await PriceTagStore.I.save(copy);
                  if (!mounted) return;
                  _toast('已另存为「${copy.name}」，现在可以随便改');
                  await _load();
                },
                onDelete: _tpls[i].builtin ? null : () => _delete(_tpls[i]),
              ),
            ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({
    required this.tpl,
    required this.onEdit,
    required this.onCopy,
    this.onDelete,
  });

  final PriceTagTemplate tpl;
  final VoidCallback onEdit;
  final VoidCallback onCopy;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(tpl.name,
                        style: const TextStyle(
                            fontSize: 15, fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text('${tpl.widthMm}×${tpl.heightMm}mm · ${tpl.elements.length} 个元素',
                        style: const TextStyle(
                            fontSize: 12, color: AppColors.textSub)),
                  ],
                ),
              ),
              if (tpl.builtin)
                const Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: _Chip(text: '内置'),
                ),
            ],
          ),
          const SizedBox(height: 10),
          // 缩略图：直接复用真预览，只是缩到每条卡片放得下的宽度
          SizedBox(
            height: 108,
            child: Center(
              child: PriceTagPreview(
                template: tpl,
                item: _sample,
                dateText: '2026-10-16',
                maxPxPerMm: 2.2,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit_outlined, size: 17),
                  label: Text(tpl.builtin ? '看一眼' : '编辑'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onCopy,
                  icon: const Icon(Icons.copy_all_outlined, size: 17),
                  label: const Text('另存'),
                ),
              ),
              if (onDelete != null) ...[
                const SizedBox(width: 8),
                IconButton(
                  tooltip: '删除',
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline,
                      size: 19, color: AppColors.danger),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.brand.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text,
          style: const TextStyle(fontSize: 11, color: AppColors.brand)),
    );
  }
}

/* ============================================================
 * 编辑器
 * ============================================================ */

/// 模板编辑器。内置模板进来是**只读**的（改一下先另存）。
///
/// 🔴 为什么内置模板不给直接改：内置那 6 套是"出厂默认"，直接改的结果是
///    每个人手机上的「标准价签 50×30」都不一样，而谁都没意识到自己改过。
///    想要自己的版本 → 另存，另存出来的才归你管。
class _TemplateEditorPage extends StatefulWidget {
  const _TemplateEditorPage({required this.initial});

  final PriceTagTemplate initial;

  @override
  State<_TemplateEditorPage> createState() => _TemplateEditorPageState();
}

class _TemplateEditorPageState extends State<_TemplateEditorPage> {
  late PriceTagTemplate _tpl;
  late final TextEditingController _name;

  @override
  void initState() {
    super.initState();
    _tpl = widget.initial;
    _name = TextEditingController(text: widget.initial.name);
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  bool get _readOnly => _tpl.builtin;

  Future<void> _save() async {
    if (_readOnly) return;
    final name = _name.text.trim();
    if (name.isEmpty) {
      _toast('给模板起个名字');
      return;
    }
    if (_tpl.elements.isEmpty) {
      _toast('至少放一个元素，不然打出来是一张白纸');
      return;
    }
    final t = _tpl.copyWith(name: name);
    await PriceTagStore.I.save(t);
    await PriceTagStore.I.setLast(t.id);
    if (!mounted) return;
    _toast('已保存');
    Navigator.pop(context);
  }

  void _toast(String s) => ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(s), duration: const Duration(seconds: 2)));

  void _move(int i, int d) {
    final j = i + d;
    if (j < 0 || j >= _tpl.elements.length) return;
    final a = List<TagElement>.from(_tpl.elements);
    final tmp = a[i];
    a[i] = a[j];
    a[j] = tmp;
    setState(() => _tpl = _tpl.copyWith(elements: a));
  }

  void _remove(int i) {
    final a = List<TagElement>.from(_tpl.elements)..removeAt(i);
    setState(() => _tpl = _tpl.copyWith(elements: a));
  }

  void _patch(int i, TagElement e) {
    final a = List<TagElement>.from(_tpl.elements);
    a[i] = e;
    setState(() => _tpl = _tpl.copyWith(elements: a));
  }

  void _add(TagElementKind kind) {
    final e = switch (kind) {
      TagElementKind.text =>
        const TagElement(kind: TagElementKind.text, field: TagField.name),
      TagElementKind.barcode =>
        const TagElement(kind: TagElementKind.barcode, align: TagAlign.center),
      TagElementKind.qrcode =>
        const TagElement(kind: TagElementKind.qrcode, align: TagAlign.center),
      TagElementKind.line => const TagElement(kind: TagElementKind.line),
    };
    final a = List<TagElement>.from(_tpl.elements)..add(e);
    setState(() => _tpl = _tpl.copyWith(elements: a));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_readOnly ? '内置模板' : '编辑模板'),
        actions: [
          if (!_readOnly)
            TextButton(onPressed: _save, child: const Text('保存')),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
        children: [
          if (_readOnly)
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.brand.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.brand.withValues(alpha: 0.3)),
              ),
              child: const Text(
                '内置模板改不了 —— 想要自己的版本，回列表页点「另存」再改。'
                '直接改内置的话，每个人手机上的「标准价签」都会长得不一样。',
                style: TextStyle(fontSize: 12.5, height: 1.5),
              ),
            ),

          // ── 纸 + 名字 ──
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _name,
                  enabled: !_readOnly,
                  decoration: const InputDecoration(
                    labelText: '模板名',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                width: 96,
                child: _IntField(
                  label: '纸宽mm',
                  value: _tpl.widthMm,
                  min: 20,
                  max: 110,
                  enabled: !_readOnly,
                  onChanged: (v) =>
                      setState(() => _tpl = _tpl.copyWith(widthMm: v)),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 96,
                child: _IntField(
                  label: '纸高mm',
                  value: _tpl.heightMm,
                  min: 15,
                  max: 300,
                  enabled: !_readOnly,
                  onChanged: (v) =>
                      setState(() => _tpl = _tpl.copyWith(heightMm: v)),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // ── 预览（改了立刻看得见）──
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFFECEFF1),
              borderRadius: BorderRadius.circular(12),
            ),
            child: PriceTagPreview(
              template: _tpl,
              item: _sample,
              dateText: '2026-10-16',
              maxPxPerMm: 3.4,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            '预览用的是一个样品（康师傅红烧牛肉面，有会员价和原价），'
            '没有会员价/原价的商品上那两行会自动整行不印。',
            style: TextStyle(fontSize: 11.5, color: AppColors.textSub),
          ),
          const SizedBox(height: 16),

          // ── 元素 ──
          Row(
            children: [
              const Text('元素',
                  style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
              const SizedBox(width: 6),
              Text('（${_tpl.elements.length}）',
                  style: const TextStyle(fontSize: 12.5, color: AppColors.textSub)),
            ],
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < _tpl.elements.length; i++)
            _ElementCard(
              index: i,
              element: _tpl.elements[i],
              canMoveUp: i > 0,
              canMoveDown: i < _tpl.elements.length - 1,
              readOnly: _readOnly,
              onMove: (d) => _move(i, d),
              onRemove: () => _remove(i),
              onPatch: (e) => _patch(i, e),
            ),
          if (!_readOnly) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () => _add(TagElementKind.text),
                  icon: const Icon(Icons.text_fields, size: 17),
                  label: const Text('加文字'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _add(TagElementKind.barcode),
                  icon: const Icon(Icons.barcode_reader, size: 17),
                  label: const Text('加条码'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _add(TagElementKind.qrcode),
                  icon: const Icon(Icons.qr_code_2_rounded, size: 17),
                  label: const Text('加二维码'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _add(TagElementKind.line),
                  icon: const Icon(Icons.horizontal_rule_rounded, size: 17),
                  label: const Text('加横线'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _IntField extends StatelessWidget {
  const _IntField({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.enabled,
    required this.onChanged,
  });

  final String label;
  final int value;
  final int min;
  final int max;
  final bool enabled;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      enabled: enabled,
      initialValue: value.toString(),
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      onChanged: (s) {
        final n = int.tryParse(s.trim());
        if (n == null) return;
        if (n < min || n > max) return;
        onChanged(n);
      },
    );
  }
}

class _ElementCard extends StatelessWidget {
  const _ElementCard({
    required this.index,
    required this.element,
    required this.canMoveUp,
    required this.canMoveDown,
    required this.readOnly,
    required this.onMove,
    required this.onRemove,
    required this.onPatch,
  });

  final int index;
  final TagElement element;
  final bool canMoveUp;
  final bool canMoveDown;
  final bool readOnly;
  final void Function(int) onMove;
  final VoidCallback onRemove;
  final ValueChanged<TagElement> onPatch;

  static const Map<TagField, String> _fieldLabel = <TagField, String>{
    TagField.name: '品名',
    TagField.spec: '规格',
    TagField.price: '售价',
    TagField.memberPrice: '会员价',
    TagField.originPrice: '原价',
    TagField.unit: '单位',
    TagField.barcode: '条码数字',
    TagField.date: '打印日期',
    TagField.seq: '序号',
    TagField.fixed: '固定文字',
  };

  @override
  Widget build(BuildContext context) {
    final e = element;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        children: [
          Row(
            children: [
              _Chip(text: '${index + 1}. ${_kindLabel(e.kind)}'),
              const Spacer(),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.arrow_upward_rounded, size: 17),
                onPressed: (readOnly || !canMoveUp) ? null : () => onMove(-1),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.arrow_downward_rounded, size: 17),
                onPressed: (readOnly || !canMoveDown) ? null : () => onMove(1),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.delete_outline,
                    size: 18, color: AppColors.danger),
                onPressed: readOnly ? null : onRemove,
              ),
            ],
          ),
          if (e.kind == TagElementKind.text) ...[
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<TagField>(
                    initialValue: e.field,
                    isDense: true,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: '内容',
                      border: OutlineInputBorder(),
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    ),
                    items: [
                      for (final f in TagField.values)
                        DropdownMenuItem<TagField>(
                          value: f,
                          child: Text(_fieldLabel[f] ?? f.name),
                        ),
                    ],
                    onChanged: readOnly
                        ? null
                        : (v) => v == null ? null : onPatch(e.copyWith(field: v)),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 88,
                  child: DropdownButtonFormField<TagAlign>(
                    initialValue: e.align,
                    isDense: true,
                    decoration: const InputDecoration(
                      labelText: '对齐',
                      border: OutlineInputBorder(),
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    ),
                    items: const [
                      DropdownMenuItem(value: TagAlign.left, child: Text('左')),
                      DropdownMenuItem(value: TagAlign.center, child: Text('中')),
                      DropdownMenuItem(value: TagAlign.right, child: Text('右')),
                    ],
                    onChanged: readOnly
                        ? null
                        : (v) => v == null ? null : onPatch(e.copyWith(align: v)),
                  ),
                ),
              ],
            ),
            if (e.field == TagField.fixed) ...[
              const SizedBox(height: 8),
              TextFormField(
                enabled: !readOnly,
                initialValue: e.fixedText,
                decoration: const InputDecoration(
                  labelText: '固定文字',
                  helperText: '如「会员专享」，别太长，会冲出纸边',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (s) => onPatch(e.copyWith(fixedText: s)),
              ),
            ],
            const SizedBox(height: 6),
            Row(
              children: [
                const Text('放大', style: TextStyle(fontSize: 12.5)),
                const SizedBox(width: 6),
                // 🔴 放大倍数直接决定"这一行能放几个字"（截断是跟着它算的），
                //    所以这里给的是 1~4 而不是 1~8：8 倍字在 40mm 纸上
                //    连两个汉字都放不下，那不是字大，那是印废了
                _Stepper(
                  label: 'X',
                  value: e.scaleX,
                  min: 1,
                  max: 4,
                  enabled: !readOnly,
                  onChanged: (v) => onPatch(e.copyWith(scaleX: v)),
                ),
                const SizedBox(width: 6),
                _Stepper(
                  label: 'Y',
                  value: e.scaleY,
                  min: 1,
                  max: 4,
                  enabled: !readOnly,
                  onChanged: (v) => onPatch(e.copyWith(scaleY: v)),
                ),
                const Spacer(),
                _Toggle(
                  label: '粗',
                  value: e.bold,
                  enabled: !readOnly,
                  onChanged: (v) => onPatch(e.copyWith(bold: v)),
                ),
                _Toggle(
                  label: '反白',
                  value: e.reverse,
                  enabled: !readOnly,
                  onChanged: (v) => onPatch(e.copyWith(reverse: v)),
                ),
                _Toggle(
                  label: '划线',
                  value: e.underline,
                  enabled: !readOnly,
                  onChanged: (v) => onPatch(e.copyWith(underline: v)),
                ),
              ],
            ),
          ],
          if (e.kind == TagElementKind.barcode) ...[
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<TagAlign>(
                    initialValue: e.align,
                    isDense: true,
                    decoration: const InputDecoration(
                      labelText: '条码对齐',
                      border: OutlineInputBorder(),
                      contentPadding:
                          EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                    ),
                    items: const [
                      DropdownMenuItem(value: TagAlign.left, child: Text('左')),
                      DropdownMenuItem(value: TagAlign.center, child: Text('中')),
                      DropdownMenuItem(value: TagAlign.right, child: Text('右')),
                    ],
                    onChanged: readOnly
                        ? null
                        : (v) => v == null ? null : onPatch(e.copyWith(align: v)),
                  ),
                ),
                const SizedBox(width: 8),
                _Stepper(
                  label: '高',
                  value: e.barcodeHeight,
                  min: 40,
                  max: 200,
                  step: 10,
                  enabled: !readOnly,
                  onChanged: (v) => onPatch(e.copyWith(barcodeHeight: v)),
                ),
                const SizedBox(width: 6),
                _Toggle(
                  label: '印数字',
                  value: e.hri,
                  enabled: !readOnly,
                  onChanged: (v) => onPatch(e.copyWith(hri: v)),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              '高度 100 点以上，扫码枪隔 20cm 才扫得动（出厂默认那点高度不行）',
              style: TextStyle(fontSize: 11, color: AppColors.textSub),
            ),
          ],
          if (e.kind == TagElementKind.qrcode)
            const Text(
              '二维码印的是商品条码。老一点的标签机可能不支持，'
              '打了出来是一串乱码就把它删掉。',
              style: TextStyle(fontSize: 11, color: AppColors.textSub),
            ),
        ],
      ),
    );
  }

  static String _kindLabel(TagElementKind k) {
    switch (k) {
      case TagElementKind.text:
        return '文字';
      case TagElementKind.barcode:
        return '条码';
      case TagElementKind.qrcode:
        return '二维码';
      case TagElementKind.line:
        return '横线';
    }
  }
}

class _Stepper extends StatelessWidget {
  const _Stepper({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.enabled,
    required this.onChanged,
    this.step = 1,
  });

  final String label;
  final int value;
  final int min;
  final int max;
  final bool enabled;
  final ValueChanged<int> onChanged;
  final int step;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label ', style: const TextStyle(fontSize: 12)),
        SizedBox(
          width: 32,
          height: 30,
          child: IconButton(
            padding: EdgeInsets.zero,
            iconSize: 16,
            onPressed: (enabled && value > min) ? () => onChanged(value - step) : null,
            icon: const Icon(Icons.remove_rounded),
          ),
        ),
        Text('$value', style: const TextStyle(fontSize: 13)),
        SizedBox(
          width: 32,
          height: 30,
          child: IconButton(
            padding: EdgeInsets.zero,
            iconSize: 16,
            onPressed: (enabled && value < max) ? () => onChanged(value + step) : null,
            icon: const Icon(Icons.add_rounded),
          ),
        ),
      ],
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({
    required this.label,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: const TextStyle(fontSize: 12.5)),
        Switch(
          value: value,
          onChanged: enabled ? onChanged : null,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ],
    );
  }
}
