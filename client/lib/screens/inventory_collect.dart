import 'dart:io';

import 'package:flutter/material.dart';

import '../api.dart';
import '../core/file_io.dart';
import '../core/inventory_export.dart';
import '../core/inventory_repo.dart';
import '../core/inventory_rules.dart';
import '../core/theme.dart';
import '../widgets/export_flow.dart';
import '../widgets/qty_edit.dart';
import 'inventory_approval.dart';
import 'inventory_grant.dart';
import 'inventory_scan.dart';

/// 盘点采集页：**一个点位 × 一个阶段**地扫。
///
/// ── 这一页和「扫码枪」差在哪 ────────────────────────────────────
/// 扫码枪只有一个状态："扫了什么、多少件"。
/// 盘点多两个维度，界面必须让人一眼看见，否则数据就串了：
///   · **阶段**（初盘 / 复盘 / 抽盘）—— 顶部三段，每段底色不同；
///   · **货架位** —— 每件商品"是在哪儿数出来的"。
/// 这两个维度是盘点的全部意义所在。少了阶段，复盘和初盘分不清；
/// 少了货架位，差异出来以后没人知道该去哪个货架找。
///
/// ── 阶段切换为什么要二次确认 ────────────────────────────────────
/// 不是怕误触，是怕**串阶段**：员工以为还在初盘、其实已经切到抽盘，
/// 一枪扫下去，这笔就记进了抽盘单 —— 而抽盘只收上一轮对不上的商品，
/// 于是"扫了没反应"。那种困惑在货架中间是解释不清的。
///
/// ── 离线 ──────────────────────────────────────────────────────
/// 这一页**只在进抽盘那一刻发过一次网络请求**（核对抽盘授权，M2），
/// 其余全程不发（商档同步是另一个入口）。那一次是**必要的例外**：
/// 授权是服务端说了算的，不问一句就没法提前告诉员工"你没这个权限" ——
/// 而等到上传时才知道，一货架的活已经白干了。
/// 问不到（断网）时**不拦**，只明说"这次没核对上"，见 [_ensureReviewGrant]。
/// 联网的动作只有两个，都在**底部主按钮**上、都由人明确点：
/// 提交之后的「上传到服务端」和上传之后的「提交审批到主管」。
/// 采集过程中一次网络请求都不发 —— 见 [_upload] / [_submitApproval]。
class InventoryCollectPage extends StatefulWidget {
  const InventoryCollectPage({
    super.key,
    required this.zoneCode,
    required this.zoneName,
  });

  final String zoneCode;
  final String zoneName;

  @override
  State<InventoryCollectPage> createState() => _InventoryCollectPageState();
}

class _InventoryCollectPageState extends State<InventoryCollectPage> {
  final InventoryRepo _repo = InventoryRepo();
  final TextEditingController _input = TextEditingController();
  final FocusNode _focus = FocusNode();

  bool _loading = true;
  bool _busy = false;
  bool _exporting = false;

  /// 正在把某个阶段的数据读进界面。
  ///
  /// 🔴 必须与 [_phase] 一起切：`_phase` 一改，界面上的阶段条、提醒语、
  ///    单号都立刻变成新阶段的，但 `_rows` 还是上一次查出来的旧数据 ——
  ///    中间那一帧会**把上一个阶段的商品显示在新的阶段标题下**。
  ///    员工瞥一眼正好看到它，就会以为"复盘里已经有这些了"。
  ///    所以切阶段时先把列表清空、挂个转圈，等数据到了再一起显示。
  bool _phaseLoading = false;

  String? _error;

  /// 当前阶段。默认初盘 —— 盘点总是从全量扫一遍开始。
  int _phase = InvPhase.first;

  /// 当前阶段的单。没扫之前可能为 null（还没开单）。
  Map<String, dynamic>? _sheet;

  List<Map<String, dynamic>> _rows = const [];
  Map<String, dynamic> _sum = const {};
  List<Map<String, dynamic>> _progress = const [];
  List<Map<String, dynamic>> _locs = const [];

  /// 当前选中的货架位。扫到没绑过货架位的商品就记在它名下。
  String? _locCode;

  /// 当前阶段的**上一阶段差异集**（复盘只收这些商品）。
  Set<String> _diffSet = const {};

  /// 抽盘（第三遍）的**复核清单**：前两遍对不上的那批商品，逐行带三遍数量。
  ///
  /// 只有抽盘用得上，其他阶段恒为空表。见 [_diffRows]。
  List<Map<String, dynamic>> _reviewRows = const [];

  /// 正在上传 / 提审。两个动作都会写服务端，连点两次就传两份，按钮必须置灰。
  bool _netBusy = false;

  /// 本单的审批状态（**只用于显示**）：null 没提审 / pending / approved / rejected。
  ///
  /// 🔴 不拿它当判据。真正的裁决在服务端（重复提审会被 409 `already_pending`
  ///    挡掉）。本地这份只是"点过之后换个文案"，问不到时保持 null、
  ///    按钮照给 —— 因为查不到状态就把入口藏起来，功能看起来就"没了"。
  ///    被驳回的理由不在这儿显示（那要另拉一次单据状态），
  ///    看「我提交的」那一栏，见 [_openApprovals]。
  String? _approvalState;

  bool get _editable =>
      _sheet == null ||
      InvSheetStatus.editable((_sheet!['status'] as num).toInt());

  /// 右上角"差异 N" / 导出 / 空状态判断都读它。
  ///
  /// 🔴 **抽盘的行集必须来自 `_reviewRows`（前两遍的差异），不能现算
  ///    `_rows.where(isDiffRow)`。** 后者判的是"抽盘 − 复盘"：
  ///    主管把数量改成跟复盘一致之后，那一行的 `diff_qty` 就成了 0，
  ///    **行会当场从表上消失** —— 可"改对了"不等于"这个商品没疑问"，
  ///    主管要最终核对的正是"前两遍对不上的那批"。
  ///    拿它当行集等于"复核得越认真、表越短"，核对台账反而丢了。
  List<Map<String, dynamic>> get _diffRows => _phase == InvPhase.third
      ? _reviewRows
      : _rows.where(InventoryRules.isDiffRow).toList();

  /// 抽盘阶段才有复核口径（未复核 / 已复核 / 复核后又改…）。
  bool get _isReview => _phase == InvPhase.third;

  /// 复核清单的计数 —— 阶段条与提交弹窗都用它，避免"差异 0 种"这种
  /// 看着像"盘完了没问题"、实际是"复核过了一遍"的错读。
  ReviewTally get _tally => InventoryRules.tallyReview(_reviewRows);

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  /// 每个阶段的底色。三个阶段必须**一眼可分** ——
  /// 颜色一样的话，员工只能靠读字确认自己在哪个阶段，会读错的。
  static Color phaseColor(int phase) {
    switch (phase) {
      case InvPhase.first:
        return AppColors.brand;
      case InvPhase.second:
        return AppColors.warn;
      default:
        return AppColors.brand2;
    }
  }

  // ============================================================
  // 载入
  // ============================================================

  Future<void> _boot() async {
    try {
      final locs = await _repo.listLocations(widget.zoneCode);
      if (!mounted) return;
      setState(() {
        _locs = locs;
        if (_locCode == null && locs.isNotEmpty) {
          _locCode = locs.first['loc_code'] as String?;
        }
      });
      await _enterPhase(InvPhase.first, firstTime: true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '读取本地数据失败：$e';
      });
    }
  }

  /// 切到某个阶段：开单（已开的直接复用）并载入该阶段的数据。
  ///
  /// [firstTime] 只影响"是否弹继续盘点提示" —— 首次进入自动落到初盘，
  /// 不该给用户弹一个他自己没点的确认框。
  Future<void> _enterPhase(int phase, {bool firstTime = false}) async {
    // 🔴 抽盘是"主管定案"那一步，进之前先确认抽盘授权（M2/P2）。
    //    拦在**进阶段之前**，不是"扫完上传时才说" —— 后者让人白扫一货架，
    //    而且他到那时才知道自己没权限，比进门就被拦住差得多。
    if (phase == InvPhase.third && !await _ensureReviewGrant()) return;
    setState(() => _busy = true);
    try {
      final existBefore = await _repo.openSheetOf(widget.zoneCode, phase);
      final sheet =
          await _repo.openSheet(zoneCode: widget.zoneCode, phase: phase);
      if (!mounted) return;
      setState(() {
        _phase = phase;
        _sheet = sheet;
        _error = null;
        // 先清空 + 转圈，避免"新阶段的标题 + 上一个阶段的行"这种串台画面
        _phaseLoading = true;
        _rows = const [];
        _sum = const {};
        _diffSet = const {};
        _reviewRows = const [];
      });
      await _refreshAll();
      if (!mounted) return;
      // "您在该盘点位有未完成数据，是否继续盘点？"—— 这里不弹框，
      // 因为**默认就是继续**（数据一条没丢，就在下面列表里）。
      // 弹一次反而会让人以为"不点继续就会丢"。
      if (!firstTime && existBefore != null) {
        final n = (_sum['kinds'] as num? ?? 0).toInt();
        if (n > 0) _snack('接着上次的${InvPhase.label(phase)}盘（已有 $n 种）');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _msgOf(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _refreshAll() async {
    final no = (_sheet?['sheet_no'] ?? '').toString();
    final sheet = no.isEmpty ? null : await _repo.findSheet(no);
    final rows = no.isEmpty
        ? const <Map<String, dynamic>>[]
        : await _repo.listRows(no);
    final sum =
        no.isEmpty ? const <String, dynamic>{} : await _repo.summary(no);
    final progress = await _repo.phaseProgress(widget.zoneCode);
    // `_diffSet` = **本阶段要复核的清单**，只有限差异集的阶段（抽盘）才有意义。
    // 🔴 别无条件去算：复盘不限差异集，算了也只会得到一个恒为空的集合，
    //    然后被空状态当成"上一轮没差异"（每次都弹那屏"没什么可盘的"）。
    //
    // 🔴 抽盘的准入集合用 `reviewBarcodes`（前两遍对不上），**不是**
    //    `diffBarcodes`（复盘 vs 初盘）：后者漏掉"复盘新扫、初盘没有"那一类
    //    （它的 prev_qty 是 null，逐行谓词判不出来），
    //    于是复核清单上列着的商品，枪上却拒收 —— 表上有的扫不进去。
    final prev = InvPhase.prev(_phase);
    final diff = (prev == null || !InvPhase.requiresDiffSetOnly(_phase))
        ? const <String>{}
        : (_phase == InvPhase.third
            ? await _repo.reviewBarcodes(widget.zoneCode)
            : await _repo.diffBarcodes(widget.zoneCode, prev));
    // 抽盘的复核清单**必须整表取**（含前两遍都有的、复盘新扫的），
    // 而且行集不随抽盘改动而变 —— 这就是"最终核对"要的台账。
    final reviewRows = _phase == InvPhase.third
        ? await _repo.diffRows(widget.zoneCode, InvPhase.third)
        : const <Map<String, dynamic>>[];
    if (!mounted) return;
    setState(() {
      if (sheet != null) _sheet = sheet;
      _rows = rows;
      _sum = sum;
      _progress = progress;
      _diffSet = diff;
      _reviewRows = reviewRows;
      _loading = false;
      _phaseLoading = false;
    });
  }

  // ============================================================
  // 扫码
  // ============================================================

  /// 扫码枪（HID 键盘）敲回车或摄像头回来，都走这里。
  Future<void> _handleCode(String raw) async {
    final code = raw.trim();
    _input.clear();
    if (code.isEmpty) return;

    // 🔴 **正在切换阶段时不能直接把这一枪丢掉。**
    //    现场的动作就是"点完『切到复盘』的确认，马上对着货架扫" ——
    //    此时开单/读库还没跑完。早先的写法在这里 `return`，那一枪就
    //    **静默消失**：界面上什么都不发生，员工以为扫上了，回头对账少一件。
    //    所以这里**等**（最多 2 秒）等它落定；真等不到也要明说没记上，
    //    绝不静默 —— 静默失败比慢两秒贵得多。
    for (var i = 0; i < 40 && _busy; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      if (!mounted) return;
    }
    if (_busy) {
      _snack('正在切换阶段，刚才那一枪没有记上，请再扫一次');
      return;
    }

    var sheet = _sheet;
    if (sheet == null) {
      await _enterPhase(_phase);
      sheet = _sheet;
      if (sheet == null) {
        _snack('开单失败，先解决上面那条报错再扫');
        return;
      }
    }
    if (!InvSheetStatus.editable((sheet['status'] as num).toInt())) {
      _snack('本单已提交，如需修改请先点「撤销提交」');
      return;
    }

    try {
      final r = await _repo.scanAuto(
        sheet['sheet_no'] as String,
        code,
        fallbackLocCode: _locCode,
      );
      if (!mounted) return;
      if (!r.accepted) {
        // 判定给的话原样转达，界面不另编一句（同一个错三种说法最让人困惑）。
        _snack(r.message ?? '这一笔没有记上');
        return;
      }
      // accepted 时还有话，只有"未绑定货架位"那一种 —— 要让人看见。
      if (r.message != null) _snack(r.message!);
      await _refreshAll();
    } catch (e) {
      if (!mounted) return;
      _snack('扫码失败：${_msgOf(e)}');
    }
  }

  // ============================================================
  // 阶段 / 提交
  // ============================================================

  // ============================================================
  // 抽盘授权闸门（M2/P2）
  // ============================================================

  /// 进抽盘之前先问一句"我有没有这个点位的抽盘授权"。
  ///
  /// 🔴 **这里只是"提前告知"，权限的裁决在服务端。** 客户端不做任何
  ///    "猜他有没有权限"的本地判断：两边各判一套，必然在某个边界
  ///    （刚授权 / 刚解除）给出不同答案，表现出来就是"界面说有权、
  ///    一上传被拒"，那是现场最难查的一类。所以这里只做三件事：
  ///
  ///      · 服务端**明确说有** → 放行，什么都不打扰；
  ///      · 服务端**明确说没有** → 拦住，并把话说明白（找谁开通）；
  ///      · **问不到**（断网 / 服务端没起 / 点位服务端还不知道）→
  ///        放行，但**明说这次没核对上**。
  ///
  ///    第三种为什么不拦死：这一页是离线优先的，弱网下主管就该能继续干活。
  ///    "问不到就拦"会把网络问题变成干不了活；而真没权限时服务端上传那一步
  ///    照样会拒 —— 那时拦的是**数据**，不是人。
  Future<bool> _ensureReviewGrant() async {
    final api = ImApi();
    // 没有登录态 = 本地单机使用，没有服务端可校，不拦。
    if (!api.hasToken) return true;

    try {
      final d = await api.stocktakeGrant(widget.zoneCode);
      if (d['mine'] == true) return true;
      if (!mounted) return false;

      final canManage = d['can_manage'] == true;
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.bgElevated,
          title:  Text('没有抽盘授权',
              style: TextStyle(color: AppColors.text, fontSize: 16)),
          content: Text(
            '您没有抽盘授权权限，请联系有权限的管理干部。\n\n'
            '（盘点位「${widget.zoneName}」。抽盘是主管定案那一步，'
            '服务端会拒绝无权账号上传的抽盘数据。）',
            style: TextStyle(color: AppColors.textSub, fontSize: 13),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('知道了')),
            if (canManage)
              TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child:  Text('去授权',
                      style: TextStyle(
                          color: AppColors.brand,
                          fontWeight: FontWeight.w600))),
          ],
        ),
      );
      if (go == true && mounted) {
        await Navigator.of(context).push(MaterialPageRoute<void>(
          builder: (_) => InventoryGrantScreen(
            zoneCode: widget.zoneCode,
            zoneName: widget.zoneName,
          ),
        ));
        // 从授权页回来后**再问一次**：他很可能刚给自己/别人开通了。
        // 不重问的话，用户得自己退出再进来一次，看着像"授权没生效"。
        return await _ensureReviewGrant();
      }
      return false;
    } catch (e) {
      if (!mounted) return false;
      // 问不到：放行 + 明说。不静默 —— 静默会让人以为"已确认过"。
      _snack('连不上服务器，这次没能核对抽盘授权；扫的数据照样能存，'
          '若确实没权限，上传时服务端会拒');
      return true;
    }
  }

  Future<void> _switchPhase(int phase) async {    if (phase == _phase || _busy) return;
    // 有一定数据就确认一下：串阶段是这一页最贵的错。
    if (_rows.isNotEmpty) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.bgElevated,
          title: Text('切到${InvPhase.label(phase)}？',
              style: TextStyle(color: AppColors.text, fontSize: 16)),
          content: Text(
            '当前是${InvPhase.label(_phase)}，已扫 ${_rows.length} 种。\n\n'
            '切换后扫进来的商品会记到「${InvPhase.label(phase)}」单里。\n'
            '${InvPhase.label(_phase)}的数据不会丢，随时可以切回去看。',
            style: TextStyle(color: AppColors.textSub, fontSize: 13),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('不切')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text('切到${InvPhase.label(phase)}',
                    style: TextStyle(
                        color: phaseColor(phase),
                        fontWeight: FontWeight.w600))),
          ],
        ),
      );
      if (ok != true) return;
    }
    await _enterPhase(phase);
  }

  Future<void> _submit() async {
    final sheet = _sheet;
    if (sheet == null) {
      _snack('还没有开始盘点，先扫一件');
      return;
    }
    final no = sheet['sheet_no'] as String;
    final label = InvPhase.label(_phase);
    final nextP = InvPhase.next(_phase);
    final kinds = _rows.length;
    final diff = _diffRows.length;
    // 🔴 抽盘不能用"差异 N 种"收尾：它的差异表是**复核清单**（前两遍对不上的），
    //    改成跟复盘一致之后那个数会归零，弹窗和提示就会说"差异 0 种"——
    //    主管看到"0"以为白盘了一遍。这里改报复核进度（还有几项没看）。
    final tally = _tally;
    final summary = _isReview
        ? '复核清单 ${tally.total} 种（前两遍对不上的），'
            '已复核 ${tally.reviewed} 种，还剩 ${tally.pending} 种没看。\n'
            '其中复核后又改了数的 ${tally.changed} 种、补盘的 ${tally.filled} 种。'
        : '品种 $kinds 种，其中差异 $diff 种。';

    // 下一步是抽盘时，先算**复核清单条数**（= 抽盘的准入集合）。
    // 🔴 不能拿 `_diffRows.length` 当门槛和话术里的数：
    //    `_diffRows` 只有"本阶段有行"的差异，**不含复盘漏盘**
    //    （初盘盘过、复盘没扫到的那批 —— 它们在复盘阶段压根没有行）。
    //    漏盘恰恰是最该复核的一类，用行数当门槛会把它们静默漏掉，
    //    最后显示"没东西可复核"。
    final nextAdmitOnly = nextP != null && InvPhase.requiresDiffSetOnly(nextP);
    final nextDiffCount =
        nextAdmitOnly ? (await _repo.reviewBarcodes(widget.zoneCode)).length : 0;
    if (!mounted) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: Text('提交$label',
            style: TextStyle(color: AppColors.text, fontSize: 16)),
        content: Text(
          '本单 $no\n'
          '$summary\n\n'
          '提交后这张单不能再改（要改得先「撤销提交」）。\n'
          '${nextP == null ? '' : (InvPhase.requiresDiffSetOnly(nextP) ? '差异集同时定格，'
              '${InvPhase.label(nextP)}就按它来复核。' : '接下来是${InvPhase.label(nextP)}：'
              '这一片要重新扫一遍，不限商品。')}',
          style: TextStyle(color: AppColors.textSub, fontSize: 13),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('再盘盘')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child:  Text('提交',
                  style: TextStyle(
                      color: AppColors.brand, fontWeight: FontWeight.w600))),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    try {
      await _repo.submitSheet(no);
      await _refreshAll();
      if (!mounted) return;
      _snack(_isReview
          ? '抽盘已提交（复核清单 ${tally.total} 种，已复核 ${tally.reviewed} 种）'
          : '$label已提交（$kinds 种，差异 $diff 种）');
      if (nextP != null) {
        // 初盘 → 复盘：这一片要重新扫一遍，**永远有活干**，直接问。
        // 复盘 → 抽盘：只有真有疑问项才值得问；两遍全对得上就别把人
        // 拉进一个扫什么都进不去的阶段（上一版拿"本轮差异数"当门槛，
        // 换了基准以后初盘的差异恒为 0，这个问句就再也不会弹了）。
        if (!nextAdmitOnly || nextDiffCount > 0) {
          await _askNextPhase(nextP, nextDiffCount);
        } else {
          _snack('初盘和复盘都对得上，没有要复核的商品');
        }
      }
    } catch (e) {
      if (!mounted) return;
      _snack('提交失败：${_msgOf(e)}');
    }
  }

  /// 提交完问一句"现在去下一阶段吗"。
  ///
  /// 这一问是有必要的：盘点的三个阶段是连着做的，
  /// 让员工自己去点那个阶段条，十次里有三次会点错（点到旁边那格）。
  Future<void> _askNextPhase(int next, int diff) async {
    final label = InvPhase.label(next);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: Text('现在开始$label？',
            style: TextStyle(color: AppColors.text, fontSize: 16)),
        content: Text(
          InvPhase.requiresDiffSetOnly(next)
              ? '上一轮有 $diff 个对不上的商品（含漏盘的）。\n'
                  '$label只收这些 —— 其他商品扫了不会被记上。'
              : '接下来是$label：这一片要重新扫一遍。\n'
                  '不限商品，初盘扫过的、没扫到的都算。',
          style: TextStyle(color: AppColors.textSub, fontSize: 13),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('待会儿')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text('开始$label',
                  style: TextStyle(
                      color: phaseColor(next), fontWeight: FontWeight.w600))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _enterPhase(next);
  }

  Future<void> _reopen() async {
    final sheet = _sheet;
    if (sheet == null) return;
    final no = sheet['sheet_no'] as String;
    final label = InvPhase.label(_phase);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: Text('撤销提交$label？',
            style: TextStyle(color: AppColors.text, fontSize: 16)),
        content: Text(
          '这张单（$no）会回到"可继续扫、可改数量"的状态。\n'
          '已经同步到服务端的数据不会因此撤销。',
          style: TextStyle(color: AppColors.textSub, fontSize: 13),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('算了')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child:  Text('撤销提交',
                  style: TextStyle(color: AppColors.danger))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _repo.reopenSheet(no);
    await _refreshAll();
    if (!mounted) return;
    _snack('$label已回到可编辑');
  }

  // ============================================================
  // 回传服务端 / 提交审批（P1 尾巴 + M2/P2）
  // ============================================================

  /// 把这张单上传到服务端。
  ///
  /// ── 上传为什么是"提交"之后的独立一步 ──────────────────────────
  /// 提交是**本地**动作（锁单、差异集定格），上传才联网。拆开是因为
  /// 货架之间没信号：提交必须随时能做，上传挑有信号的时候做。
  /// 合成一步的话，断网时按"提交"就会把这一遍的数卡死在手机上。
  ///
  /// 🔴 上传成功后本地**立刻**也置成"已上传"。服务端是上传即归档；
  ///    本地不跟着归档，重传时服务端会 409、而本地还以为没传上去，
  ///    员工会反复点，最后没人知道哪一份是准的。
  Future<void> _upload() async {
    final sheet = _sheet;
    if (sheet == null) return;
    final no = sheet['sheet_no'] as String;
    final label = InvPhase.label(_phase);

    final api = ImApi();
    if (!api.hasToken) {
      _snack('还没登录服务器，先登录后再上传');
      return;
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: Text('上传$label到服务端？',
            style: TextStyle(color: AppColors.text, fontSize: 16)),
        content: Text(
          '本单 $no，共 ${_rows.length} 种商品。\n\n'
          '上传后服务端就把这张单归档，之后默认不能再覆盖 —— '
          '这是为了「盘点结果不能事后修饰」。\n'
          '传完还要改的话，得先找主管处理。\n\n'
          '（这张单的本地数据不会被清掉，随时还能查看和导出。）',
          style: TextStyle(color: AppColors.textSub, fontSize: 13),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('再想想')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child:  Text('上传',
                  style: TextStyle(
                      color: AppColors.brand, fontWeight: FontWeight.w600))),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _netBusy = true);
    try {
      final payload = await _repo.uploadPayload(no);
      final rows = (payload['rows'] as List).cast<Map<String, dynamic>>();
      if (rows.isEmpty) {
        _snack('这张单一条商品都没有，没有可上传的数据');
        return;
      }
      final res = await api.uploadStocktakeSheet(
        sheetNo: no,
        phase: payload['phase'] as int,
        rows: rows,
        zone: Map<String, dynamic>.from(payload['zone'] as Map),
        bindings: (payload['bindings'] as List).cast<Map<String, dynamic>>(),
      );
      await _repo.markUploaded(no);
      await _refreshAll();
      if (!mounted) return;

      final rejected = (res['rejected'] as List?) ?? const <dynamic>[];
      final accepted = (res['accepted'] as num?)?.toInt() ?? rows.length;
      final buf = StringBuffer('$label已上传，服务端收下 $accepted 条');
      if (rejected.isNotEmpty) buf.write('，拒收 ${rejected.length} 条');
      // 服务端还没有前两遍数据时不校复核清单（整场断网跑完再一次性上传）。
      // 这种情况下**必须说**：不说，主管会以为"清单已经校过了、没问题"。
      if (payload['phase'] == InvPhase.third && res['diff_checked'] == false) {
        buf.write('；服务端暂无前两遍数据，这次没校复核清单');
      }
      _snack(buf.toString());
      if (rejected.isNotEmpty) await _showRejectedDialog(rejected);
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.code == 'already_uploaded') {
        // 服务端已经有这张单 = 数据在服务端。按服务端口径归档本地。
        // 最常见的原因是上次上传的回执丢了（弱网），不是"有人改了数"。
        // 🔴 但**必须说出来**，不能静默当成功：万一本地这份和服务端那份
        //    不一样，用户有权知道"这次没有覆盖服务端"。
        await _repo.markUploaded(no);
        await _refreshAll();
        if (!mounted) return;
        _snack('服务端已有这张单，本次没有覆盖它；本地已记为已上传');
      } else if (e.code == 'not_in_diff_set') {
        final bad = (e.data?['barcodes'] as List?) ?? const <dynamic>[];
        final total = (e.data?['total_bad'] as num?)?.toInt() ?? bad.length;
        _snack('服务端拒收：抽盘只复核前两遍对不上的商品，这 $total 种不在清单里');
        if (bad.isNotEmpty) {
          await _showRejectedDialog(bad
              .map((b) => <String, dynamic>{
                    'barcode': b,
                    'reason': '不在复核清单里',
                  })
              .toList());
        }
      } else if (e.code == 'zone_not_found') {
        _snack('服务端没有这个盘点位，先在服务端建好点位再上传');
      } else if (e.isUnauthorized) {
        _snack('登录已失效，请重新登录后再上传');
      } else {
        _snack('上传失败：${e.message}');
      }
    } catch (e) {
      if (!mounted) return;
      _snack('上传失败：${_msgOf(e)}');
    } finally {
      if (mounted) setState(() => _netBusy = false);
    }
  }

  /// 把服务端拒收的行摆出来（最多列 50 条）。
  ///
  /// 🔴 只弹一句"有 N 条被拒"是不够的：被拒的行**没进服务端**，
  ///    员工不把码改对，那份盘点就少了东西 —— 而单子上写着"已上传"。
  ///    所以要把条码和原因逐条列出来。
  Future<void> _showRejectedDialog(List<dynamic> rejected) async {
    if (!mounted) return;
    final items = rejected.take(50).toList();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: Text('有 ${rejected.length} 条没传上去',
            style: TextStyle(color: AppColors.text, fontSize: 16)),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final r in items)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Text(
                      '${(r as Map)['barcode']} — ${r['reason'] ?? '未说明'}',
                      style:  TextStyle(
                          color: AppColors.danger, fontSize: 12),
                    ),
                  ),
                if (rejected.length > items.length)
                  Text('…还有 ${rejected.length - items.length} 条',
                      style:  TextStyle(
                          color: AppColors.textWeak, fontSize: 12)),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('知道了')),
        ],
      ),
    );
  }

  /// 把这张单提交审批（`kind=stocktake`，`ref` 是单号）。
  ///
  /// 🔴 必须先上传。服务端在提交审批时要查这张单在不在（`inv_sheets`），
  ///    没上传只会得到 404「盘点单不存在」—— 与其让人对着这句话猜，
  ///    不如在本地就说清楚要先上传。
  Future<void> _submitApproval() async {
    final sheet = _sheet;
    if (sheet == null) return;
    final no = sheet['sheet_no'] as String;
    final status = (sheet['status'] as num).toInt();
    if (status != InvSheetStatus.uploaded) {
      _snack('这张单还没上传到服务端，先上传再提审');
      return;
    }
    final label = InvPhase.label(_phase);

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title:  Text('提交审批？',
            style: TextStyle(color: AppColors.text, fontSize: 16)),
        content: Text(
          '本单 $no（$label，${_rows.length} 种商品）交给主管审批。\n\n'
          '主管可以「通过」或「驳回」；被驳回时理由会显示出来。',
          style: TextStyle(color: AppColors.textSub, fontSize: 13),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('不提')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child:  Text('提交',
                  style: TextStyle(
                      color: AppColors.brand, fontWeight: FontWeight.w600))),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _netBusy = true);
    try {
      await ImApi().submitApproval(
        kind: 'stocktake',
        ref: no,
        title: '${widget.zoneName} · $label · $no',
        // 快照给主管看：审批列表不 join 盘点表也能看出"这是哪一单、多大"。
        payload: <String, dynamic>{
          'zone_code': widget.zoneCode,
          'zone_name': widget.zoneName,
          'phase': _phase,
          'kinds': _rows.length,
          'total_qty': _sum['total_qty'],
          'diff_kinds': _diffRows.length,
        },
      );
      if (!mounted) return;
      setState(() => _approvalState = 'pending');
      _snack('已提交审批，等主管处理');
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.code == 'already_pending') {
        setState(() => _approvalState = 'pending');
        _snack('这张单已经在审批中，等主管处理');
      } else if (e.status == 404) {
        _snack('服务端没有这张单，请先「上传到服务端」再提审');
      } else if (e.isForbidden) {
        _snack('只能提交自己的盘点单审批');
      } else if (e.isUnauthorized) {
        _snack('登录已失效，请重新登录');
      } else {
        _snack('提交审批失败：${e.message}');
      }
    } catch (e) {
      if (!mounted) return;
      _snack('提交审批失败：${_msgOf(e)}');
    } finally {
      if (mounted) setState(() => _netBusy = false);
    }
  }

  // ============================================================
  // 货架位
  // ============================================================

  Future<void> _newLocation() async {
    final ctl = TextEditingController();
    final nameCtl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title:  Text('新建货架位',
            style: TextStyle(color: AppColors.text, fontSize: 16)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              key: const Key('loc-code-input'),
              controller: ctl,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              style: TextStyle(color: AppColors.text, fontSize: 15),
              decoration:  InputDecoration(
                labelText: '货架位码（如 A01）',
                labelStyle:
                    TextStyle(color: AppColors.textWeak, fontSize: 13),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('loc-name-input'),
              controller: nameCtl,
              style: TextStyle(color: AppColors.text, fontSize: 15),
              decoration:  InputDecoration(
                labelText: '名字（可留空）',
                labelStyle:
                    TextStyle(color: AppColors.textWeak, fontSize: 13),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child:  Text('建好',
                  style: TextStyle(
                      color: AppColors.brand, fontWeight: FontWeight.w600))),
        ],
      ),
    );
    final code = ctl.text.trim();
    final nm = nameCtl.text.trim();
    ctl.dispose();
    nameCtl.dispose();
    if (ok != true || !mounted) return;
    if (code.isEmpty) {
      _snack('货架位码不能为空');
      return;
    }
    try {
      await _repo.saveLocation(
          locCode: code, zoneCode: widget.zoneCode, name: nm.isEmpty ? code : nm);
      final locs = await _repo.listLocations(widget.zoneCode);
      if (!mounted) return;
      setState(() {
        _locs = locs;
        _locCode = code;
      });
      _snack('已建货架位 $code，之后的商品默认记在它名下');
    } catch (e) {
      _snack('新建失败：${_msgOf(e)}');
    }
  }

  /// 把某行商品绑到当前货架位。
  ///
  /// 这是"货架位档案"的**唯一**建法：员工在货架前扫一遍该货架上的商品，
  /// 顺手绑一次，档案就这样一天天补齐。所以这个动作必须一步可达。
  Future<void> _bindToCurrentLoc(Map<String, dynamic> r) async {
    final lc = _locCode;
    if (lc == null || lc.isEmpty) {
      _snack('先在上面选一个货架位');
      return;
    }
    final bc = r['barcode'].toString();
    try {
      await _repo.bindBarcode(bc, lc);
      await _refreshAll();
      if (!mounted) return;
      _snack('已把 $bc 绑到货架位 $lc');
    } catch (e) {
      _snack('绑定失败：${_msgOf(e)}');
    }
  }

  // ============================================================
  // 行操作
  // ============================================================

  Future<void> _editQty(Map<String, dynamic> r) async {
    if (!_editable) {
      _snack('本单已提交，改数量前先「撤销提交」');
      return;
    }
    final cur = (r['qty'] as num?)?.toDouble() ?? 0;
    final v = await askQty(
      context,
      subtitle: '${InventoryExport.nameOf(r)}　${r['barcode']}',
      current: cur,
      confirmText: '确定把 ${r['barcode']} 这一行删掉？',
      onMessage: _snack,
    );
    if (v == null || !mounted) return;
    final id = r['id'] as int;
    if (v == 0) {
      await _repo.deleteRow(id);
    } else {
      await _repo.setQty(id, v);
    }
    await _refreshAll();
    if (!mounted) return;
    _snack(v == 0 ? '已删掉这一行' : '已改成 ${fmtQty(v)}');
  }

  Future<void> _rowMenu(Map<String, dynamic> r) async {
    final act = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: AppColors.bgElevated,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                title: Text(
                  '${InventoryExport.nameOf(r)}　${r['barcode']}',
                  style: TextStyle(color: AppColors.text, fontSize: 13),
                ),
              ),
              if (_editable)
                ListTile(
                  key: const Key('row-menu-bind'),
                  leading: Icon(Icons.link, color: AppColors.brand),
                  title: Text(
                      _locCode == null
                          ? '绑到货架位（先选一个货架位）'
                          : '绑到货架位 $_locCode',
                      style: TextStyle(color: AppColors.text)),
                  onTap: () => Navigator.pop(ctx, 'bind'),
                ),
              ListTile(
                key: const Key('row-menu-where'),
                leading:  Icon(Icons.place_outlined,
                    color: AppColors.textSub),
                title:  Text('看它在哪些货架位',
                    style: TextStyle(color: AppColors.text)),
                onTap: () => Navigator.pop(ctx, 'where'),
              ),
              if (_editable)
                ListTile(
                  key: const Key('row-menu-delete'),
                  leading:  Icon(Icons.delete_outline,
                      color: AppColors.danger),
                  title:  Text('删掉这一行',
                      style: TextStyle(color: AppColors.danger)),
                  onTap: () => Navigator.pop(ctx, 'delete'),
                ),
              ListTile(
                leading: Icon(Icons.close, color: AppColors.textWeak),
                title:  Text('先不用',
                    style: TextStyle(color: AppColors.textSub)),
                onTap: () => Navigator.pop(ctx),
              ),
            ],
          ),
        ),
      ),
    );
    if (act == null || !mounted) return;
    if (act == 'bind') {
      await _bindToCurrentLoc(r);
      return;
    }
    if (act == 'where') {
      await _showWhereBound(r['barcode'].toString());
      return;
    }
    if (act == 'delete') {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.bgElevated,
          title:  Text('删掉这一行？',
              style: TextStyle(color: AppColors.text, fontSize: 16)),
          content: Text('${InventoryExport.nameOf(r)}　${r['barcode']}',
              style: TextStyle(color: AppColors.textSub, fontSize: 13)),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消')),
            TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child:  Text('删除',
                    style: TextStyle(color: AppColors.danger))),
          ],
        ),
      );
      if (ok != true || !mounted) return;
      await _repo.deleteRow(r['id'] as int);
      await _refreshAll();
      if (!mounted) return;
      _snack('已删掉这一行');
    }
  }

  Future<void> _showWhereBound(String barcode) async {
    final rows = await _repo.locationsOfBarcode(barcode);
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.bgElevated,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('$barcode 绑定的货架位',
                  style:  TextStyle(
                      color: AppColors.text,
                      fontSize: 15,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 10),
              if (rows.isEmpty)
                 Text(
                  '一个都没绑。\n\n'
                  '这不影响盘：扫它照样能记，只是"记在哪儿"要靠你上面选的货架位。\n'
                  '在货架前把它绑一次，以后它就知道自己在哪儿了。',
                  style: TextStyle(
                      color: AppColors.textSub, fontSize: 13, height: 1.6),
                )
              else
                for (final r in rows)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      children: [
                         Icon(Icons.place,
                            size: 16, color: AppColors.brand),
                        const SizedBox(width: 6),
                        Text(
                          '${r['zone_code']} / ${r['loc_code']}'
                          '${(r['zone_name'] ?? '') == '' ? '' : '（${r['zone_name']}）'}',
                          style:  TextStyle(
                              color: AppColors.text, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
  }

  // ============================================================
  // 差异表 / 导出
  // ============================================================

  Future<void> _showDiffSheet() async {
    final phase = _phase;
    // 🔴 用 diffRows 而不是 phaseRows：漏盘（上一轮盘过、这一轮没扫到）
    //    在本阶段没有扫码记录，phaseRows 里根本没有那一行。
    //
    // 🔴 而且抽盘（第三遍）拿回来的是**复核清单**：行集由"初盘 vs 复盘"决定，
    //    不是"抽盘 − 复盘"。复核改对之后后者会变 0、整行从表里消失，
    //    而主管最终核对要看的正是"前两遍就对不上的那批"。
    final isReview = phase == InvPhase.third;
    final diffs = await _repo.diffRows(widget.zoneCode, phase);
    final mistakes = await _repo.mistakeCount(widget.zoneCode, phase);
    final missed = diffs.where((r) => r['missing'] == true).length;
    final tally = InventoryRules.tallyReview(diffs);
    if (!mounted) return;

    // 金额口径跟着台账走：
    //   · 复核清单 = **前两遍**的差异金额（要核对的那笔账）
    //   · 其它阶段 = 本遍比上一遍的差异金额
    // 复核清单里若用"抽盘 − 复盘"，复核改对后全是 0，金额列等于白给。
    var loss = 0.0;
    var gain = 0.0;
    var noAccount = 0;
    for (final r in diffs) {
      if (r['account_qty'] == null) {
        noAccount++;
        continue;
      }
      final a =
          isReview ? InventoryExport.baseAmtOf(r) : InventoryExport.amtOf(r);
      if (a == null) continue;
      if (a < 0) {
        loss += -a;
      } else {
        gain += a;
      }
    }

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.bgElevated,
      isScrollControlled: true,
      builder: (ctx) => FractionallySizedBox(
        heightFactor: 0.84,
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
                child: Row(
                  children: [
                    Icon(isReview ? Icons.fact_check_outlined : Icons.rule,
                        size: 18, color: phaseColor(phase)),
                    const SizedBox(width: 8),
                    Text(isReview ? '抽盘复核' : '${InvPhase.label(phase)}差异',
                        style:  TextStyle(
                            color: AppColors.text,
                            fontSize: 16,
                            fontWeight: FontWeight.w600)),
                    const Spacer(),
                    Text('盘点位 ${widget.zoneCode}',
                        style:  TextStyle(
                            color: AppColors.textWeak, fontSize: 11)),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: isReview
                      ? <Widget>[
                          _statChip('复核项', '${tally.total}'),
                          _statChip('已复核', '${tally.reviewed}',
                              color: tally.reviewed > 0
                                  ? AppColors.brand
                                  : null),
                          _statChip('未复核', '${tally.pending}',
                              color:
                                  tally.pending > 0 ? AppColors.danger : null),
                          _statChip('复核后又改', '${tally.changed}',
                              color:
                                  tally.changed > 0 ? AppColors.warn : null),
                          _statChip('补盘', '${tally.filled}'),
                          _statChip('前两遍漏盘', '${tally.baseMissing}',
                              color: tally.baseMissing > 0
                                  ? AppColors.warn
                                  : null),
                          _statChip('前两遍亏', loss.toStringAsFixed(2),
                              color: AppColors.danger),
                          _statChip('前两遍盈', gain.toStringAsFixed(2),
                              color: AppColors.brand),
                          _statChip('账面缺失', '$noAccount',
                              color: noAccount > 0 ? AppColors.warn : null),
                          _statChip('失误笔数', '$mistakes',
                              color: mistakes > 0 ? AppColors.warn : null),
                        ]
                      : <Widget>[
                          _statChip('差异品种', '${diffs.length}'),
                          _statChip('盘亏', loss.toStringAsFixed(2),
                              color: AppColors.danger),
                          _statChip('盘盈', gain.toStringAsFixed(2),
                              color: AppColors.brand),
                          _statChip('漏盘', '$missed',
                              color: missed > 0 ? AppColors.warn : null),
                          _statChip('账面缺失', '$noAccount',
                              color: noAccount > 0 ? AppColors.warn : null),
                          _statChip('失误笔数', '$mistakes',
                              color: mistakes > 0 ? AppColors.warn : null),
                        ],
                ),
              ),
              const SizedBox(height: 10),
              const Divider(height: 1),
              Expanded(
                child: diffs.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(28),
                          child: Text(
                            isReview
                                ? '没有要复核的商品。\n\n'
                                    '（复核清单 = 初盘和复盘对不上的那些商品，'
                                    '含初盘盘过、复盘没扫到的"漏盘"。一条都没有，'
                                    '说明前两遍完全一致，抽盘无需复核。）'
                                : '这个阶段没有差异。\n\n'
                                    '（差异 = 这一遍的数量跟上一遍对不上，含上一遍盘过、'
                                    '这一遍没扫到的"漏盘"。一条都没有，说明两遍完全一致；'
                                    '也可能是这一阶段还没扫。）',
                            textAlign: TextAlign.center,
                            style:  TextStyle(
                                color: AppColors.textWeak,
                                fontSize: 13,
                                height: 1.7),
                          ),
                        ),
                      )
                    : ListView.separated(
                        padding: const EdgeInsets.only(top: 4, bottom: 12),
                        itemCount: diffs.length,
                        separatorBuilder: (_, __) =>
                            const Divider(height: 1, indent: 16),
                        itemBuilder: (_, i) => isReview
                            ? _reviewTile(diffs[i], i + 1)
                            : _diffTile(diffs[i], i + 1),
                      ),
              ),
              if (diffs.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 6, 16, 14),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          key: const Key('export-diff-csv'),
                          onPressed: () => _exportDiff(phase, asDoc: false),
                          icon: const Icon(Icons.table_chart_outlined,
                              size: 18),
                          label: const Text('导出表格'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton.tonalIcon(
                          key: const Key('export-diff-doc'),
                          onPressed: () => _exportDiff(phase, asDoc: true),
                          icon: const Icon(Icons.description_outlined,
                              size: 18),
                          label: const Text('导出文档（发主管）'),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 抽盘复核清单的一行：三遍数量并排 + 复核结论。
  ///
  /// 和 [_diffTile] 分开写而不是加个开关：两个台账要看的重点不一样 ——
  /// 差异表看"这一遍比上一遍差多少"，复核清单看"这商品前两遍怎么对不上的、
  /// 复核之后结论是什么"。硬塞进一个方法会出现一堆 `if (isReview)`。
  /// 复核行里"某一遍的数量"：有数就是 `标签 数字`，缺数就是 `标签（占位词）`。
  ///
  /// 抽成函数只为了**三段的空格一模一样** —— 手写三遍很容易写出
  /// "抽盘 （未复核）"这种括号前多一个空格的排版，一行里三格对不齐。
  static String seg(String label, Object? v, String miss) {
    final n = InventoryRules.asNum(v);
    return n == null ? '$label$miss' : '$label ${fmtQty(n)}';
  }

  Widget _reviewTile(Map<String, dynamic> r, int idx) {
    final a1 = r['base_qty']; // 初盘
    final a2 = r['prev_qty']; // 复盘
    final reviewed = r['review_missing'] != true;
    final a3 = reviewed ? r['qty'] : null; // 抽盘（没复核就是空）
    final verdict = (r['review'] ?? '').toString();
    final acc = r['account_qty'];
    final baseDiff = (r['base_diff'] as num?)?.toDouble();
    final amt = InventoryExport.baseAmtOf(r);
    final baseMissing = r['base_missing'] == true;

    // 未复核要最显眼：它意味着"这一项还没人看过"。
    final Color vColor;
    switch (verdict) {
      case InventoryRules.reviewAligned:
        vColor = AppColors.brand;
        break;
      case InventoryRules.reviewChanged:
        vColor = AppColors.warn;
        break;
      case InventoryRules.reviewFilled:
        vColor = AppColors.textSub;
        break;
      default:
        vColor = AppColors.danger;
    }
    final dColor = baseDiff == null
        ? AppColors.textWeak
        : (baseDiff < 0 ? AppColors.danger : AppColors.brand);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 24,
            child: Text('$idx',
                style:  TextStyle(
                    color: AppColors.textWeak, fontSize: 12)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(InventoryExport.nameOf(r),
                    style:  TextStyle(
                        color: AppColors.text, fontSize: 14),
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 3),
                Text(
                  '${r['barcode']}'
                  '${baseMissing ? '　【复盘漏盘】' : ''}'
                  '　账面 ${acc == null ? '（账上没这商品）' : fmtQty(acc)}',
                  style: TextStyle(
                      color: baseMissing ? AppColors.warn : AppColors.textWeak,
                      fontSize: 11),
                ),
                const SizedBox(height: 3),
                // 三遍数量并排 —— 最终核对就看这一行。
                // "没盘过/未复核"这些占位词**不要数字前面那个空格**
                // （写出来会变成"抽盘 （未复核）"，顿在括号前很别扭）；
                // 用同一个 seg 拼，三条的间距才一致。
                Text(
                  [
                    seg('初盘', a1, '（没盘过）'),
                    seg('复盘', a2, '（没盘过）'),
                    seg('抽盘', a3, '（未复核）'),
                  ].join(' → '),
                  style:  TextStyle(
                      color: AppColors.textSub, fontSize: 12),
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: vColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        InventoryRules.reviewVerdictLabel(verdict),
                        style: TextStyle(color: vColor, fontSize: 11),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text('前两遍差 ${baseDiff == null ? '—' : fmtQty(baseDiff)}',
                        style: TextStyle(color: dColor, fontSize: 11)),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // 右侧大数字给"前两遍的差异"：这才是要核对的账。
              // 给"抽盘 − 复盘"的话，复核改对后恒为 0，等于没有信息。
              Text(baseDiff == null ? '—' : fmtQty(baseDiff),
                  style: TextStyle(
                      color: dColor, fontSize: 15, fontWeight: FontWeight.w600)),
              if (amt != null)
                Text(amt.toStringAsFixed(2),
                    style: TextStyle(color: dColor, fontSize: 11)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _diffTile(Map<String, dynamic> r, int idx) {
    final acc = r['account_qty'];
    final prev = r['prev_qty'];
    final missing = r['missing'] == true;
    final d = (r['diff_qty'] as num?)?.toDouble();
    final amt = InventoryExport.amtOf(r);
    // 盘亏红、盘盈绿？（这个项目里"涨红跌绿"是中国习惯，
    // 但盘亏≠涨。这里按"亏了要引起注意"给色：亏损用 danger。）
    final c = d == null
        ? AppColors.textWeak
        : (d < 0 ? AppColors.danger : AppColors.brand);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 24,
            child: Text('$idx',
                style:  TextStyle(
                    color: AppColors.textWeak, fontSize: 12)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(InventoryExport.nameOf(r),
                    style:  TextStyle(
                        color: AppColors.text, fontSize: 14),
                    overflow: TextOverflow.ellipsis),
                const SizedBox(height: 3),
                Text(
                  '${r['barcode']}'
                  '${missing ? '　【漏盘】' : ''}'
                  '　实盘 ${fmtQty(r['qty'])}'
                  '　上一遍 ${prev == null ? '（没盘过）' : fmtQty(prev)}'
                  '　账面 ${acc == null ? '（账上没这商品）' : fmtQty(acc)}',
                  style: TextStyle(
                      color: missing ? AppColors.warn : AppColors.textWeak,
                      fontSize: 11),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(d == null ? '—' : fmtQty(d),
                  style: TextStyle(
                      color: c, fontSize: 15, fontWeight: FontWeight.w600)),
              if (amt != null)
                Text(amt.toStringAsFixed(2),
                    style: TextStyle(color: c, fontSize: 11)),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _exportDiff(int phase, {required bool asDoc}) async {
    try {
      // 同 _showDiffSheet：漏盘要一起导出去，否则发给主管的那份少一类。
      // 抽盘拿回来的是**复核清单**（见 diffRows 的注释），所以这里的分支
      // 不只是换个标题 —— CSV 的列和文档的抬头都不一样，走复核那一套。
      final isReview = phase == InvPhase.third;
      final diffs = await _repo.diffRows(widget.zoneCode, phase);
      if (diffs.isEmpty) {
        _snack(isReview
            ? '初盘和复盘都对得上，没有要复核的商品'
            : '${InvPhase.label(phase)}没有差异，不用导出');
        return;
      }
      final mistakes = await _repo.mistakeCount(widget.zoneCode, phase);
      final name = FileIo.safeName(isReview
          ? (asDoc
              ? InventoryExport.reviewDocName(widget.zoneCode)
              : InventoryExport.reviewName(widget.zoneCode))
          : (asDoc
              ? InventoryExport.diffDocName(widget.zoneCode, phase)
              : InventoryExport.diffName(widget.zoneCode, phase)));
      final text = isReview
          ? (asDoc
              ? InventoryExport.toReviewDoc(diffs,
                  zoneName: widget.zoneName, mistakes: mistakes)
              : InventoryExport.toReviewCsv(diffs))
          : (asDoc
              ? InventoryExport.toDiffDoc(
                  diffs,
                  zoneName: widget.zoneName,
                  phaseLabel: InvPhase.label(phase),
                  mistakes: mistakes,
                )
              : InventoryExport.toDiffCsv(diffs));
      final dir = await FileIo.dir();
      final f = File('${dir.path}${Platform.pathSeparator}$name');
      await f.writeAsString(text); // UTF-8；CSV 的 BOM 由导出层负责
      if (!mounted) return;
      await ExportFlow.show(context, f,
          rows: diffs.length, suggestName: name, onMessage: _snack);
    } catch (e) {
      if (!mounted) return;
      _snack('导出失败：${_msgOf(e)}');
    }
  }

  Future<void> _exportRows({required bool asDoc}) async {
    final sheet = _sheet;
    if (sheet == null || _rows.isEmpty) {
      _snack('这个阶段还没有扫码记录，先扫几条再导出');
      return;
    }
    final no = sheet['sheet_no'] as String;
    setState(() => _exporting = true);
    try {
      final name = FileIo.safeName(asDoc
          ? InventoryExport.docName(no)
          : InventoryExport.csvName(no));
      final text = asDoc
          ? InventoryExport.toRowsDoc(_rows,
              sheetNo: no,
              zoneName: widget.zoneName,
              phaseLabel: InvPhase.label(_phase))
          : InventoryExport.toRowsCsv(_rows);
      final dir = await FileIo.dir();
      final f = File('${dir.path}${Platform.pathSeparator}$name');
      await f.writeAsString(text);
      if (!mounted) return;
      setState(() => _exporting = false);
      await ExportFlow.show(context, f,
          rows: _rows.length, suggestName: name, onMessage: _snack);
    } catch (e) {
      if (!mounted) return;
      setState(() => _exporting = false);
      _snack('导出失败：${_msgOf(e)}');
    }
  }

  Future<void> _clearZoneData() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title:  Text('清除本点位盘点数据（不可恢复）',
            style: TextStyle(color: AppColors.text, fontSize: 16)),
        content: Text(
          '会删掉「${widget.zoneName}」下所有阶段的盘点单与扫码明细。\n'
          '点位、货架位、商品绑定这些档案会保留。\n\n'
          '（只清本机数据，已经同步到服务端的不会被删。）',
          style: TextStyle(color: AppColors.textSub, fontSize: 13),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child:
                  Text('清除', style: TextStyle(color: AppColors.danger))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      final r = await _repo.clearZoneData(widget.zoneCode);
      await _enterPhase(InvPhase.first);
      if (!mounted) return;
      _snack('已清除 ${r['sheet'] ?? 0} 张单、${r['scan_record'] ?? 0} 条明细');
    } catch (e) {
      _snack('清除失败：${_msgOf(e)}');
    }
  }

  Future<void> _openCamera() async {
    var sheet = _sheet;
    if (sheet == null) {
      await _enterPhase(_phase);
      sheet = _sheet;
      if (sheet == null) return;
    }
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => InventoryScanPage(
          sheetNo: sheet!['sheet_no'] as String,
          repo: _repo,
          locCode: _locCode,
          phaseLabel: InvPhase.label(_phase),
        ),
      ),
    );
    if (!mounted) return;
    await _refreshAll();
  }

  // ============================================================
  // 界面
  // ============================================================

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 把异常揉成一句人话。裸 `$e` 会带上 `StateError: ` 这种前缀，
  /// 现场看到的应该是"盘点位已锁定，请先解除锁定"。
  static String _msgOf(Object e) {
    final s = e.toString();
    return s.replaceFirst(RegExp(r'^\w*Exception: '), '').replaceFirst(
        RegExp(r'^Bad state: '), '');
  }

  @override
  Widget build(BuildContext context) {
    final pc = phaseColor(_phase);
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bgElevated,
        title: Text(widget.zoneName,
            style: TextStyle(color: AppColors.text, fontSize: 17)),
        actions: [
          IconButton(
            key: const Key('inv-diff-btn'),
            // 抽盘这张表是"复核清单"不是"差异表" —— 打开后拿到的东西
            // 根本不是同一份台账（行集由前两遍决定），名字要跟上。
            tooltip: _phase == InvPhase.third
                ? '抽盘复核清单'
                : '${InvPhase.label(_phase)}差异表',
            icon: Icon(
                _phase == InvPhase.third ? Icons.fact_check_outlined : Icons.rule,
                color: AppColors.textSub),
            onPressed: _loading ? null : _showDiffSheet,
          ),
          PopupMenuButton<String>(
            icon: Icon(Icons.more_vert, color: AppColors.textSub),
            onSelected: (v) {
              if (v == 'clear') _clearZoneData();
              if (v == 'approvals') _openApprovals();
            },
            itemBuilder: (_) => [
              // 单据状态固定摆在菜单第一行（不可点）：主按钮会随状态变形
              // （提交→上传→提审），得有一个**稳定**的地方能看出当前是哪一态，
              // 否则"按钮上写着提交审批"和"这单到底传没传"只能靠记。
              PopupMenuItem<String>(
                enabled: false,
                child: Text(
                  '本单：${InvSheetStatus.label((_sheet?['status'] as num?)?.toInt() ?? InvSheetStatus.open)}',
                  style:  TextStyle(
                      color: AppColors.textWeak, fontSize: 12),
                ),
              ),
              const PopupMenuItem<String>(
                  value: 'approvals', child: Text('查看审批进度')),
              const PopupMenuItem<String>(
                  value: 'clear', child: Text('清除本点位盘点数据')),
            ],
          ),
        ],
      ),
      bottomNavigationBar: _loading ? null : _bottomBar(),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                if (_error != null) _banner(_error!, AppColors.danger),
                _phaseBar(),
                _locBar(),
                _inputBar(),
                _notice(pc),
                _statBar(pc),
                Expanded(
                  child: _phaseLoading
                      ? const Center(child: CircularProgressIndicator())
                      : (_rows.isEmpty
                          ? _empty(pc)
                          : ListView.separated(
                              padding: const EdgeInsets.only(bottom: 10),
                              itemCount: _rows.length,
                              separatorBuilder: (_, __) =>
                                  const Divider(height: 1, indent: 14),
                              itemBuilder: (_, i) => _rowTile(_rows[i], i + 1),
                            )),
                ),
              ],
            ),
    );
  }

  Widget _banner(String text, Color color) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        color: color.withValues(alpha: 0.14),
        child: Text(text, style: TextStyle(color: color, fontSize: 13)),
      );

  /// 阶段条：三段并排，当前那段用**自己的阶段色**填底。
  Widget _phaseBar() => Container(
        color: AppColors.bgElevated,
        padding: const EdgeInsets.fromLTRB(11, 8, 11, 8),
        child: Row(
          children: [
            for (final p in InvPhase.all) _phaseTab(p),
          ],
        ),
      );

  Widget _phaseTab(int phase) {
    final item = _progress.firstWhere(
      (x) => (x['phase'] as num).toInt() == phase,
      orElse: () => <String, dynamic>{'phase': phase},
    );
    final active = phase == _phase;
    final c = phaseColor(phase);
    final status = (item['status'] as num? ?? -1).toInt();
    final kinds = (item['kinds'] as num? ?? 0).toInt();
    final diff = (item['diff'] as num? ?? 0).toInt();
    final pendingReview = (item['pending_review'] as num?)?.toInt();
    final statusText = status == -1 ? '未开始' : InvSheetStatus.label(status);
    // 抽盘的头条数字是"还剩几项没复核"（见 phaseProgress 的注释）。
    // 没有它的时候（老数据 / 非抽盘）退回原来的"差 N"。
    final subText = kinds == 0
        ? statusText
        : (pendingReview != null
            ? '$kinds 种 · 待复核 $pendingReview'
            : '$kinds 种 · 差 $diff');

    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: InkWell(
          key: Key('inv-phase-$phase'),
          borderRadius: BorderRadius.circular(AppRadii.sm),
          onTap: () => _switchPhase(phase),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
            decoration: BoxDecoration(
              color: active
                  ? c.withValues(alpha: 0.16)
                  : AppColors.surface,
              borderRadius: BorderRadius.circular(AppRadii.sm),
              border: Border.all(
                  color: active ? c : AppColors.border,
                  width: active ? 1.4 : 1),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        InvPhase.label(phase),
                        style: TextStyle(
                            color: active ? c : AppColors.textSub,
                            fontSize: 13,
                            fontWeight:
                                active ? FontWeight.w700 : FontWeight.w500),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 4),
                    if (status != -1)
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                            color: c,
                            borderRadius: BorderRadius.circular(999)),
                      ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  subText,
                  style:  TextStyle(
                      color: AppColors.textWeak, fontSize: 10),
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 货架位选择条。现场的做法是"人站在哪个货架前就选哪个"。
  Widget _locBar() => Container(
        color: AppColors.bgElevated,
        padding: const EdgeInsets.fromLTRB(11, 0, 11, 8),
        child: Row(
          children: [
             Icon(Icons.place_outlined,
                size: 15, color: AppColors.textWeak),
            const SizedBox(width: 5),
             Text('货架位：',
                style: TextStyle(color: AppColors.textWeak, fontSize: 12)),
            Expanded(
              child: SizedBox(
                height: 30,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    if (_locs.isEmpty)
                       Center(
                        child: Text('还没建，扫到没绑过的商品会不记货架位',
                            style: TextStyle(
                                color: AppColors.textWeak, fontSize: 11)),
                      )
                    else
                      for (final l in _locs) _locChip(l),
                  ],
                ),
              ),
            ),
            InkWell(
              key: const Key('inv-new-loc'),
              borderRadius: BorderRadius.circular(999),
              onTap: _newLocation,
              child:  Padding(
                padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.add, size: 14, color: AppColors.brand),
                    Text('新建',
                        style: TextStyle(
                            color: AppColors.brand,
                            fontSize: 12,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
          ],
        ),
      );

  Widget _locChip(Map<String, dynamic> l) {
    final code = (l['loc_code'] ?? '').toString();
    final active = code == _locCode;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: InkWell(
        key: Key('inv-loc-$code'),
        borderRadius: BorderRadius.circular(999),
        onTap: () => setState(() => _locCode = code),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: active
                ? AppColors.brand.withValues(alpha: 0.18)
                : AppColors.surface,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
                color: active ? AppColors.brand : AppColors.border, width: 1),
          ),
          child: Text(
            (l['loc_name'] ?? code).toString(),
            style: TextStyle(
                color: active ? AppColors.brand : AppColors.textSub,
                fontSize: 12,
                fontWeight: active ? FontWeight.w600 : FontWeight.normal),
          ),
        ),
      ),
    );
  }

  Widget _inputBar() => Container(
        color: AppColors.bgElevated,
        padding: const EdgeInsets.fromLTRB(11, 0, 11, 10),
        child: Row(
          children: [
            // 手机端把「扫码」放最左、给足面积 —— 现场大多数店没有扫码枪，
            // 摄像头才是主路径，输入框是兜底。
            if (InventoryScanPage.supported) ...[
              Material(
                color: AppColors.brand.withValues(alpha: 0.16),
                borderRadius: BorderRadius.circular(AppRadii.sm),
                child: InkWell(
                  key: const Key('inv-camera'),
                  borderRadius: BorderRadius.circular(AppRadii.sm),
                  onTap: _openCamera,
                  child:  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 11),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.qr_code_scanner,
                            color: AppColors.brand, size: 20),
                        SizedBox(width: 6),
                        Text('扫码',
                            style: TextStyle(
                                color: AppColors.brand,
                                fontSize: 13,
                                fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: TextField(
                key: const Key('inv-scan-input'),
                controller: _input,
                focusNode: _focus,
                autofocus: true,
                // 🔴 **不能**用 TextInputType.visiblePassword：Android 会把它
                // 当密码框，弹出来的是密码安全键盘，数字全变圆点。
                // 要的是"关掉输入法干预"，那是下面两个开关的活。
                keyboardType: TextInputType.text,
                enableSuggestions: false,
                autocorrect: false,
                textInputAction: TextInputAction.done,
                style: TextStyle(color: AppColors.text, fontSize: 15),
                decoration: InputDecoration(
                  hintText: '扫码枪直接打，或手输条码回车',
                  hintStyle:
                      TextStyle(color: AppColors.textWeak, fontSize: 13),
                  filled: true,
                  fillColor: AppColors.surface,
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                ),
                onSubmitted: _handleCode,
              ),
            ),
          ],
        ),
      );

  /// 当前阶段最重要的一句提醒。
  Widget _notice(Color pc) {
    String? text;
    Color c = pc;
    if (_phase == InvPhase.second) {
      text = '复盘是这一片重新盘一遍（不限商品）。'
          '不用照着差异表来 —— 谁都可能看漏。';
      c = AppColors.brand2;
    } else if (_phase == InvPhase.third) {
      text = '抽盘是主管复核：只收前两遍对不上的商品（含漏盘的，'
          '共 ${_diffSet.length} 种）。扫其他商品不会被记上。'
          '复核结果看右上角"复核清单"。';
      c = AppColors.warn;
    }
    if (text == null) return const SizedBox.shrink();
    return _banner(text, c);
  }

  Widget _statBar(Color pc) => Container(
        color: AppColors.bgElevated,
        padding: const EdgeInsets.fromLTRB(14, 0, 14, 9),
        child: Row(
          children: [
            Expanded(
              child: Text(
                _sheet == null ? '还没开始' : (_sheet!['sheet_no'] ?? '').toString(),
                style: TextStyle(color: AppColors.textWeak, fontSize: 11),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            _statChip('品种', '${_sum['kinds'] ?? 0}'),
            const SizedBox(width: 6),
            _statChip('合计', fmtQty(_sum['total_qty'])),
            const SizedBox(width: 6),
            // 抽盘这一格报的是**待复核数**（前两遍对不上、还没复核的），
            // 不是"抽盘 − 复盘"。后者复核改对之后会掉到 0，
            // 看着像"盘完了没问题"，其实只是"复核过了一遍"。
            if (_isReview) ...[
              _statChip('待复核', '${_tally.pending}',
                  color: _tally.pending == 0 ? null : AppColors.warn),
            ] else
              _statChip('差异', '${_diffRows.length}',
                  color: _diffRows.isEmpty ? null : AppColors.warn),
            if (((_sum['unknown'] as num? ?? 0).toInt()) > 0) ...[
              const SizedBox(width: 6),
              _statChip('未知 ${_sum['unknown']}', '',
                  color: AppColors.warn),
            ],
          ],
        ),
      );

  Widget _statChip(String label, String value, {Color? color}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: (color ?? AppColors.textSub).withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(
          value.isEmpty ? label : '$label $value',
          style: TextStyle(color: color ?? AppColors.textSub, fontSize: 11),
        ),
      );

  /// 空状态的外壳：**有空间就居中，没空间就滚动**。
  ///
  /// 🔴 不能直接 `Center(child: Column(...))`：小屏 + 系统大字体下整块会
  ///    **溢出**（实测溢出 5.8px），最下面那个按钮被顶到屏幕外**点不到**。
  ///    空状态里恰恰放着最该点得着的那个按钮（"直接去抽盘"），
  ///    点不到就等于这条路没给。
  Widget _emptyShell(Widget child) => LayoutBuilder(
        builder: (_, cons) => SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: cons.maxHeight),
            child: Center(child: child),
          ),
        ),
      );

  Widget _empty(Color pc) {
    // 抽盘阶段 + 上一轮零差异 = 这一遍**没东西可复核**。
    // 必须给一条出路：否则按钮因为"一条都没扫"而灰着，主管卡在这儿
    // 出不去（初盘和复盘全对得上，在门店是常态，不是异常）。
    if (_phase == InvPhase.third && _diffSet.isEmpty) {
      return _emptyShell(
        Padding(
          // 底部留 96：浮动的 SnackBar 就飘在这块区域上方，
          // 不留的话"提示弹出那 4 秒"里按钮被压住**点不动**（实测命中测试失败）。
          padding: const EdgeInsets.fromLTRB(28, 28, 28, 96),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.task_alt, size: 44, color: AppColors.brand),
              const SizedBox(height: 14),
               Text('前两遍都对得上',
                  style: TextStyle(color: AppColors.text, fontSize: 15)),
              const SizedBox(height: 10),
               Text(
                '初盘和复盘没盘出差异，这一遍没有要复核的商品。\n'
                '回点位看一眼差异表就行。',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: AppColors.textWeak, fontSize: 13, height: 1.7),
              ),
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                key: const Key('inv-back-to-zone'),
                onPressed: () => Navigator.of(context).maybePop(),
                icon: const Icon(Icons.arrow_back, size: 18),
                label: const Text('返回点位'),
              ),
            ],
          ),
        ),
      );
    }

    return _emptyShell(
      Padding(
        padding: const EdgeInsets.fromLTRB(28, 28, 28, 96),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.qr_code_scanner, size: 44, color: pc),
            const SizedBox(height: 14),
            Text('${InvPhase.label(_phase)}还没扫',
                style: TextStyle(color: AppColors.text, fontSize: 15)),
            const SizedBox(height: 10),
            Text(
              _emptyHint(),
              textAlign: TextAlign.center,
              style:  TextStyle(
                  color: AppColors.textWeak, fontSize: 13, height: 1.7),
            ),
          ],
        ),
      ),
    );
  }

  String _emptyHint() {
    switch (_phase) {
      case InvPhase.second:
        return '这一遍把这整片重新扫一遍。\n'
            '初盘扫过的、没扫到的都算，不用照着差异表来。';
      case InvPhase.third:
        return '这一遍只复核上一轮对不上的商品。\n'
            '差异表里那 ${_diffSet.length} 个商品扫一遍就行。';
      default:
        return '对着货架上的条码一路扫。\n'
            '扫错了或者要改数量，点右边那个数量格。';
    }
  }

  Widget _rowTile(Map<String, dynamic> r, int idx) {
    final bc = r['barcode'].toString();
    final unknown = (r['name'] ?? '').toString().trim().isEmpty;
    final acc = r['account_qty'];
    final d = (r['diff_qty'] as num?)?.toDouble();
    final lc = (r['loc_code'] ?? '').toString();
    final isDiff = InventoryRules.isDiffRow(r);

    return InkWell(
      key: Key('inv-row-$bc'),
      onLongPress: () => _rowMenu(r),
      child: Container(
        color: isDiff ? AppColors.warn.withValues(alpha: 0.045) : null,
        padding: const EdgeInsets.fromLTRB(14, 9, 10, 9),
        child: Row(
          children: [
            SizedBox(
              width: 26,
              child: Text('$idx',
                  style:  TextStyle(
                      color: AppColors.textWeak, fontSize: 12)),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    InventoryExport.nameOf(r),
                    style: TextStyle(
                        color: unknown ? AppColors.warn : AppColors.text,
                        fontSize: 14,
                        fontWeight: FontWeight.w500),
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          bc,
                          style:  TextStyle(
                              color: AppColors.textWeak, fontSize: 11),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (lc.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Icon(Icons.place,
                            size: 11,
                            color: AppColors.textWeak.withValues(alpha: 0.9)),
                        Text(lc,
                            style:  TextStyle(
                                color: AppColors.textWeak, fontSize: 11)),
                      ],
                      if (acc != null) ...[
                        const SizedBox(width: 6),
                        Text('账面 ${fmtQty(acc)}',
                            style:  TextStyle(
                                color: AppColors.textWeak, fontSize: 11)),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (d != null && d != 0)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Text(
                  '${d > 0 ? '+' : ''}${fmtQty(d)}',
                  style: TextStyle(
                      color: d < 0 ? AppColors.danger : AppColors.brand,
                      fontSize: 12,
                      fontWeight: FontWeight.w600),
                ),
              ),
            _qtyPill(r, bc),
          ],
        ),
      ),
    );
  }

  /// 数量格 —— **做成有底色的小胶囊**。
  ///
  /// 一行纯文字里没人看得出"这个数字能点"。所以给它底色、加 tooltip，
  /// 并且 key 固定成 `inv-qty-<条码>`，测试才能精确点到"这一行"。
  Widget _qtyPill(Map<String, dynamic> r, String barcode) {
    final locked = !_editable;
    return Tooltip(
      message: locked ? '本单已提交，先撤销提交' : '点这里改数量',
      child: InkWell(
        key: Key('inv-qty-$barcode'),
        borderRadius: BorderRadius.circular(AppRadii.sm),
        onTap: locked ? null : () => _editQty(r),
        child: Container(
          constraints: const BoxConstraints(minWidth: 56),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: locked
                ? AppColors.surface
                : AppColors.brand.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(AppRadii.sm),
            border: Border.all(
                color: locked ? AppColors.border : AppColors.brand,
                width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                fmtQty(r['qty']),
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: locked ? AppColors.textWeak : AppColors.brand,
                    fontSize: 15,
                    fontWeight: FontWeight.w700),
              ),
              if (!locked) ...[
                const SizedBox(width: 4),
                Icon(Icons.edit,
                    size: 11,
                    color: AppColors.brand.withValues(alpha: 0.75)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 打开审批中心，直接落在「我提交的」。
  ///
  /// 从采集页进来的人看的是**自己的单**有没有批过 / 被驳回，
  /// 默认停在「待我审批」会让他对着一份和自己无关的列表找。
  Future<void> _openApprovals() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => const InventoryApprovalScreen(initialTab: 1),
    ));
  }

  Widget _bottomBar() {
    final editable = _editable;
    final hasSheet = _sheet != null;
    // 🔴 **一条都没扫就不给提交。**
    //    提交 = "这一遍我盘完了"。空手点一下就把初盘标记成完成，
    //    差异集随之定格为空 —— 后面的复盘、抽盘全部建立在"没有差异"上，
    //    整条链报废，而且**没有任何报错**，等对账时才发现。
    //    宁可让人先扫一件，也不能让这个动作随手可及。
    final canSubmit = hasSheet && !_phaseLoading && _rows.isNotEmpty;
    final status =
        hasSheet ? (_sheet!['status'] as num).toInt() : InvSheetStatus.open;

    // ── 主按钮只放"下一步该干的那件事" ────────────────────────────
    // 能扫 → 提交；已提交 → 上传；已上传 → 提审。
    // 🔴 回退动作（撤销提交）**从主按钮位挪到右边的图标里**：
    //    盘完一遍之后最该点的是"上传"，让它和"撤销提交"并排摆着，
    //    现场十次里会有三次点到撤销 —— 而撤销之后单据回到可改，
    //    差异集跟着重新定格，那不是"手滑一下"，是数据口径变了。
    final Widget primary;
    if (editable) {
      primary = FilledButton.icon(
        key: const Key('inv-submit'),
        onPressed: canSubmit ? _submit : null,
        icon: const Icon(Icons.check, size: 18),
        label: Text(canSubmit ? '提交${InvPhase.label(_phase)}' : '先扫一件再提交'),
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(44)),
      );
    } else if (status == InvSheetStatus.submitted) {
      primary = FilledButton.icon(
        key: const Key('inv-upload'),
        onPressed: _netBusy ? null : _upload,
        icon: _netBusy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.cloud_upload_outlined, size: 18),
        label: Text(_netBusy ? '正在上传…' : '上传到服务端'),
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(44)),
      );
    } else {
      primary = FilledButton.icon(
        key: const Key('inv-submit-approval'),
        onPressed: _netBusy ? null : _submitApproval,
        icon: _netBusy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.verified_outlined, size: 18),
        label: Text(
            _approvalState == 'pending' ? '已提交审批' : '提交审批到主管'),
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(44)),
      );
    }

    return Container(
      color: AppColors.bgElevated,
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      child: SafeArea(
        top: false,
        child: Row(
          children: [
            Expanded(child: primary),
            const SizedBox(width: 4),
            // 撤销提交只在"已提交、还没上传"时可用。
            // 已上传的单**本地回不去**（服务端已归档，本地放回可改只会
            // 造成"改了却传不上去"，两边对不上），所以那个状态下不出现。
            if (!editable && status == InvSheetStatus.submitted)
              IconButton(
                key: const Key('inv-reopen'),
                tooltip: '撤销提交（回到可继续扫、可改数量）',
                onPressed: _netBusy ? null : _reopen,
                icon:  Icon(Icons.lock_open,
                    size: 20, color: AppColors.warn),
              ),
            IconButton(
              key: const Key('inv-export-csv'),
              tooltip: '导出本阶段明细表格',
              onPressed: _exporting ? null : () => _exportRows(asDoc: false),
              icon: _exporting
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  :  Icon(Icons.table_chart_outlined,
                      color: AppColors.textSub),
            ),
            IconButton(
              key: const Key('inv-export-doc'),
              tooltip: '导出本阶段明细文档',
              onPressed: _exporting ? null : () => _exportRows(asDoc: true),
              icon:  Icon(Icons.description_outlined,
                  color: AppColors.textSub),
            ),
          ],
        ),
      ),
    );
  }
}
