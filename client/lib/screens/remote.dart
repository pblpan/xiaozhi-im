// 远程协助 UI（入口 / 控制端画布 / 被控端警示条 / 请求确认）
//
// 【设计原则：安全感优先】
// 远程协助会把自己的屏幕给出去、让别人动自己的键鼠。所以界面上凡是涉及
// "正在被控"的状态，必须是**醒目的、无法忽略的、随时能一键断开的**。
// 宁可丑一点，也不要让用户在"不知道自己正在被控"的状态下做事。

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart'; // 指针事件（Pointer* / kSecondaryButton）
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // 键盘事件（Key*Event / LogicalKeyboardKey）
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../api.dart';
import '../core/input_inject.dart';
import '../core/remote_assist.dart';
import '../core/remote_models.dart';
import '../core/theme.dart';

// ============================================================ 入口页

/// 远程协助首页：发起协助 / 用码连接 / 访问码管理 / 会话记录
class RemoteHubScreen extends StatefulWidget {
  const RemoteHubScreen({super.key});

  @override
  State<RemoteHubScreen> createState() => _RemoteHubScreenState();
}

class _RemoteHubScreenState extends State<RemoteHubScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);
  final _svc = RemoteAssistService.instance;

  @override
  void initState() {
    super.initState();
    _svc.start();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      appBar: AppBar(
        backgroundColor: AppColors.bgElevated,
        title: const Text('远程协助'),
        bottom: TabBar(
          controller: _tabs,
          labelColor: AppColors.brand,
          unselectedLabelColor: AppColors.textSub,
          indicatorColor: AppColors.brand,
          tabs: const [
            Tab(text: '发起 / 连接'),
            Tab(text: '我的访问码'),
            Tab(text: '协助记录'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: const [_ConnectTab(), _CodesTab(), _HistoryTab()],
      ),
    );
  }
}

// ---------------------------------------------------------------- 连接

class _ConnectTab extends StatefulWidget {
  const _ConnectTab();

  @override
  State<_ConnectTab> createState() => _ConnectTabState();
}

class _ConnectTabState extends State<_ConnectTab> {
  final _code = TextEditingController();
  final _target = TextEditingController();
  String? _msg;
  bool _busy = false;

  @override
  void dispose() {
    _code.dispose();
    _target.dispose();
    super.dispose();
  }

  Future<void> _redeem() async {
    final c = _code.text.trim();
    if (c.isEmpty) {
      setState(() => _msg = '请输入对方给你的 9 位访问码');
      return;
    }
    setState(() { _busy = true; _msg = null; });
    final err = await RemoteAssistService.instance.redeem(c);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (err != null) _msg = err;
    });
    if (err == null && mounted) await _openControl();
  }

  Future<void> _invite() async {
    final id = int.tryParse(_target.text.trim());
    if (id == null) {
      setState(() => _msg = '请输入对方的账号 ID（纯数字）');
      return;
    }
    final err = await RemoteAssistService.instance.requestFrom(id);
    if (!mounted) return;
    if (err != null) {
      setState(() => _msg = err);
      return;
    }
    setState(() => _msg = '已发起请求，等待对方同意…');
  }

  Future<void> _openControl() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => const RemoteControlScreen()),
    );
  }

  @override
  Widget build(BuildContext context) {
    final svc = RemoteAssistService.instance;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('用访问码连接', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              const Text(
                '对方离线也能连（无人值守）。连上后对方仍有 10 秒可以拒绝，'
                '不会在你不知道的情况下直接被控。',
                style: TextStyle(fontSize: 12.5, color: AppColors.textSub, height: 1.5),
              ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _code,
                    keyboardType: TextInputType.number,
                    maxLength: 9,
                    style: const TextStyle(letterSpacing: 3, fontSize: 17),
                    decoration: const InputDecoration(
                      hintText: '9 位数字',
                      counterText: '',
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton(
                  onPressed: _busy ? null : _redeem,
                  child: _busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('连接'),
                ),
              ]),
            ],
          ),
        ),
        const SizedBox(height: 12),
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('请求对方协助', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              const Text(
                '对方必须在线并点「同意」才开始。适合临时帮同事处理问题。',
                style: TextStyle(fontSize: 12.5, color: AppColors.textSub, height: 1.5),
              ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _target,
                    keyboardType: TextInputType.number,
                    style: const TextStyle(fontSize: 15),
                    decoration: const InputDecoration(hintText: '对方账号 ID', isDense: true),
                  ),
                ),
                const SizedBox(width: 10),
                OutlinedButton(onPressed: _invite, child: const Text('发起')),
              ]),
              const SizedBox(height: 8),
              const Text(
                '暂时用账号 ID 指定对方。后续会把通讯录好友直接做成选择列表。',
                style: TextStyle(fontSize: 11.5, color: AppColors.textWeak),
              ),
            ],
          ),
        ),
        if (_msg != null) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(_msg!, style: const TextStyle(fontSize: 12.5, color: AppColors.brand2)),
          ),
        ],
        const SizedBox(height: 16),
        // 会话进行中时给个入口，别让用户以为断了
        ValueListenableBuilder<RemotePhase>(
          valueListenable: svc.phase,
          builder: (_, p, __) {
            if (p == RemotePhase.idle || p == RemotePhase.ended) return const SizedBox.shrink();
            return ListTile(
              tileColor: AppColors.surface,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              leading: const Icon(Icons.desktop_windows_rounded, color: AppColors.brand),
              title: const Text('返回进行中的会话'),
              subtitle: Text(_phaseText(p)),
              trailing: TextButton(
                onPressed: () => RemoteAssistService.instance.hangUp(),
                child: const Text('结束', style: TextStyle(color: AppColors.danger)),
              ),
              onTap: _openControl,
            );
          },
        ),
      ],
    );
  }
}

String _phaseText(RemotePhase p) {
  switch (p) {
    case RemotePhase.idle:
      return '空闲';
    case RemotePhase.requesting:
      return '等待对方同意…';
    case RemotePhase.connecting:
      return '正在建立连接…';
    case RemotePhase.active:
      return '会话进行中';
    case RemotePhase.ended:
      return '已结束';
  }
}

// ---------------------------------------------------------------- 访问码

class _CodesTab extends StatefulWidget {
  const _CodesTab();

  @override
  State<_CodesTab> createState() => _CodesTabState();
}

class _CodesTabState extends State<_CodesTab> {
  List<RemoteCode> _items = [];
  bool _loading = true;
  String? _err;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _err = null; });
    try {
      final list = await ImApi().remoteCodes();
      if (!mounted) return;
      setState(() { _items = list; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _err = '$e'; _loading = false; });
    }
  }

  Future<void> _create() async {
    final label = await showDialog<String>(
      context: context,
      builder: (ctx) => _NewCodeDialog(),
    );
    if (label == null) return;
    try {
      final r = await ImApi().createRemoteCode(label: label);
      if (!mounted) return;
      final code = r['code']?.toString() ?? '';
      await showDialog<void>(
        context: context,
        builder: (_) => _CodeOnceDialog(code: code),
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      setState(() => _err = '生成失败：$e');
    }
  }

  Future<void> _revoke(RemoteCode c) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgElevated,
        title: const Text('吊销这个访问码？'),
        content: const Text(
          '吊销后立刻失效，之前拿到这个码的人将无法连接。'
          '如果你怀疑码泄漏了，就吊销它。',
          style: TextStyle(fontSize: 13.5, color: AppColors.textSub, height: 1.5),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('吊销', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await ImApi().revokeRemoteCode(c.id);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_err != null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(_err!, style: const TextStyle(color: AppColors.danger, fontSize: 13)),
          const SizedBox(height: 10),
          OutlinedButton(onPressed: _load, child: const Text('重试')),
        ]),
      );
    }
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
        child: Row(children: [
          const Expanded(
            child: Text(
              '访问码是「别人能在你不在场时连你电脑」的钥匙。'
              '只在你确实需要长期值守时才开。',
              style: TextStyle(fontSize: 12, color: AppColors.textSub, height: 1.5),
            ),
          ),
          const SizedBox(width: 10),
          FilledButton.icon(
            onPressed: _create,
            icon: const Icon(Icons.add_rounded, size: 17),
            label: const Text('生成'),
          ),
        ]),
      ),
      Expanded(
        child: _items.isEmpty
            ? const Center(
                child: Text('还没有访问码',
                    style: TextStyle(color: AppColors.textWeak, fontSize: 13)),
              )
            : RefreshIndicator(
                onRefresh: _load,
                child: ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _items.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final c = _items[i];
                    final dead = c.expired || c.usedUp;
                    return Opacity(
                      opacity: dead ? 0.45 : 1,
                      child: ListTile(
                        tileColor: AppColors.surface,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                        leading: Icon(
                          dead ? Icons.block_rounded : Icons.vpn_key_rounded,
                          color: dead ? AppColors.textWeak : AppColors.brand,
                        ),
                        title: Text(c.label.isEmpty ? '未命名' : c.label),
                        subtitle: Text(
                          '${c.singleUse ? '一次性' : '长期'}'
                          '${c.expiresAt != null ? ' · 有有效期' : ''}'
                          ' · 已用 ${c.useCount} 次'
                          '${dead ? ' · 已失效' : ''}',
                          style: const TextStyle(fontSize: 12),
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.delete_outline_rounded, color: AppColors.danger),
                          tooltip: '吊销',
                          onPressed: () => _revoke(c),
                        ),
                      ),
                    );
                  },
                ),
              ),
      ),
    ]);
  }
}

/// 新建访问码
class _NewCodeDialog extends StatefulWidget {
  @override
  State<_NewCodeDialog> createState() => _NewCodeDialogState();
}

class _NewCodeDialogState extends State<_NewCodeDialog> {
  final _label = TextEditingController();
  bool _single = false;
  int _ttl = 0; // 分钟，0 = 长期

  @override
  void dispose() {
    _label.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.bgElevated,
      title: const Text('新建访问码'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _label,
            decoration: const InputDecoration(
              labelText: '备注（给自己认的）',
              hintText: '如：门店前台那台',
              isDense: true,
            ),
          ),
          const SizedBox(height: 6),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: const Text('一次性（用完自动作废）', style: TextStyle(fontSize: 13.5)),
            value: _single,
            onChanged: (v) => setState(() => _single = v),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: [
              for (final opt in const <(int, String)>[(0, '长期'), (60, '1 小时'), (1440, '24 小时'),
                    (10080, '7 天')])
                ChoiceChip(
                  label: Text(opt.$2, style: const TextStyle(fontSize: 12)),
                  selected: _ttl == opt.$1,
                  onSelected: (_) => setState(() => _ttl = opt.$1),
                ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        TextButton(
          onPressed: () => Navigator.pop(context, _label.text.trim()),
          child: const Text('生成'),
        ),
      ],
    );
  }
}

/// 明文只显示一次的弹窗 —— 关掉就再也找不回来了，必须说清楚
class _CodeOnceDialog extends StatelessWidget {
  const _CodeOnceDialog({required this.code});
  final String code;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.bgElevated,
      title: const Text('请把这个码发给对方'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 16),
            decoration: BoxDecoration(
              color: AppColors.surfaceHi,
              borderRadius: BorderRadius.circular(10),
            ),
            child: SelectableText(
              code,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 30, letterSpacing: 8, fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            '⚠️ 关掉这个窗口之后就查不到了（服务端只存哈希，不存明文）。\n'
            '现在没记下的话，只能吊销它重新生成一个。',
            style: TextStyle(fontSize: 12.5, color: AppColors.warn, height: 1.6),
          ),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('我记下了')),
      ],
    );
  }
}

// ---------------------------------------------------------------- 记录

class _HistoryTab extends StatefulWidget {
  const _HistoryTab();

  @override
  State<_HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends State<_HistoryTab> {
  List<RemoteSessionRecord> _items = [];
  bool _loading = true;
  String? _err;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _err = null; });
    try {
      final list = await ImApi().remoteSessions();
      if (!mounted) return;
      setState(() { _items = list; _loading = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _err = '$e'; _loading = false; });
    }
  }

  String _fmt(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    return '${d.year}-${'${d.month}'.padLeft(2, '0')}-${'${d.day}'.padLeft(2, '0')} '
        '${'${d.hour}'.padLeft(2, '0')}:${'${d.minute}'.padLeft(2, '0')}';
  }

  String _dur(int sec) {
    if (sec < 60) return '$sec 秒';
    final m = sec ~/ 60;
    final s = sec % 60;
    if (m < 60) return s == 0 ? '$m 分钟' : '$m 分 $s 秒';
    return '${m ~/ 60} 小时 ${m % 60} 分';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_err != null) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(_err!, style: const TextStyle(color: AppColors.danger, fontSize: 13)),
          const SizedBox(height: 10),
          OutlinedButton(onPressed: _load, child: const Text('重试')),
        ]),
      );
    }
    if (_items.isEmpty) {
      return const Center(child: Text('还没有远程协助记录', style: TextStyle(color: AppColors.textWeak)));
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: _items.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (_, i) {
          final r = _items[i];
          final host = r.role == RemoteRole.host;
          return ListTile(
            tileColor: AppColors.surface,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            leading: Icon(
              host ? Icons.screen_share_rounded : Icons.mouse_rounded,
              color: host ? AppColors.warn : AppColors.brand,
            ),
            title: Text(host ? '${r.peerName} 协助了你' : '你协助了 ${r.peerName}'),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 3),
                Text(_fmt(r.createdAt), style: const TextStyle(fontSize: 12)),
                if (r.durationSec > 0)
                  Text('时长 ${_dur(r.durationSec)}'
                      '${r.endReason.isNotEmpty ? ' · ${remoteEndReasonText(r.endReason)}' : ''}',
                      style: const TextStyle(fontSize: 12)),
              ],
            ),
            isThreeLine: r.durationSec > 0,
            trailing: Text(
              r.mode == 'unattended' ? '无人值守' : '有人值守',
              style: const TextStyle(fontSize: 11.5, color: AppColors.textWeak),
            ),
          );
        },
      ),
    );
  }
}

// ============================================================ 控制端画布

/// 控制端界面：显示对方屏幕 + 把本地鼠标键盘事件转成指令发出去
/// 把一个 Flutter 按键事件翻译成要发给被控端的 RemoteKey。
///
/// 【为什么单独抽成纯函数】
/// 这段是整个远程协助里最容易出错、又最难靠肉眼验证的部分：
/// 少映射一个修饰键的表象不是"报错"，而是"对方电脑上按不出 Ctrl+C"，
/// 用户只会觉得软件难用，且极难复现。抽出来才能单测，才有改动的兜底。
RemoteKey? remoteKeyOf(LogicalKeyboardKey logical, String? character) {
  if (logical == LogicalKeyboardKey.tab) return const RemoteKey(vk: Vk.tab);
  if (logical == LogicalKeyboardKey.backspace) return const RemoteKey(vk: Vk.backspace);
  if (logical == LogicalKeyboardKey.enter) return const RemoteKey(vk: Vk.enter);
  if (logical == LogicalKeyboardKey.escape) return const RemoteKey(vk: Vk.escape);
  if (logical == LogicalKeyboardKey.arrowUp) return const RemoteKey(vk: Vk.up, extended: true);
  if (logical == LogicalKeyboardKey.arrowDown) return const RemoteKey(vk: Vk.down, extended: true);
  if (logical == LogicalKeyboardKey.arrowLeft) return const RemoteKey(vk: Vk.left, extended: true);
  if (logical == LogicalKeyboardKey.arrowRight) return const RemoteKey(vk: Vk.right, extended: true);
  if (logical == LogicalKeyboardKey.home) return const RemoteKey(vk: Vk.home, extended: true);
  if (logical == LogicalKeyboardKey.end) return const RemoteKey(vk: Vk.end, extended: true);
  if (logical == LogicalKeyboardKey.pageUp) return const RemoteKey(vk: Vk.pageUp, extended: true);
  if (logical == LogicalKeyboardKey.pageDown) return const RemoteKey(vk: Vk.pageDown, extended: true);
  if (logical == LogicalKeyboardKey.delete) return const RemoteKey(vk: Vk.delete, extended: true);
  if (logical == LogicalKeyboardKey.insert) return const RemoteKey(vk: Vk.insert, extended: true);

  // ---- 修饰键 ----
  // ⚠️ 这一组**绝对不能少**。曾经漏掉整个组的后果是：在被控电脑上做不出
  // 任何组合键（Ctrl+C / Ctrl+V / Alt+Tab / Win+D 全废），而这是个靠
  // 看画面很难定位的问题 —— 鼠标、打字都正常，就是复制粘贴不行。
  // 组合键是"序列"不是"单键"：这里把修饰键作为独立的按下/抬起事件发出去，
  // 被控端按原顺序注入，Ctrl+C 自然就成立。
  if (logical == LogicalKeyboardKey.controlLeft) {
    return const RemoteKey(vk: Vk.control);
  }
  if (logical == LogicalKeyboardKey.controlRight) {
    return const RemoteKey(vk: Vk.control, extended: true);
  }
  if (logical == LogicalKeyboardKey.shiftLeft) {
    return const RemoteKey(vk: Vk.shift);
  }
  if (logical == LogicalKeyboardKey.shiftRight) {
    return const RemoteKey(vk: Vk.shift, extended: true);
  }
  if (logical == LogicalKeyboardKey.altLeft) {
    return const RemoteKey(vk: Vk.alt);
  }
  if (logical == LogicalKeyboardKey.altRight) {
    return const RemoteKey(vk: Vk.alt, extended: true);
  }
  if (logical == LogicalKeyboardKey.metaLeft) {
    return const RemoteKey(vk: Vk.meta);
  }
  if (logical == LogicalKeyboardKey.metaRight) {
    return const RemoteKey(vk: Vk.meta, extended: true);
  }

  // F1..F12（远程排障时 F5 刷新、F2 改名这类很常用）
  final f = _fKeys[logical];
  if (f != null) return RemoteKey(vk: f);

  // 可打印字符走 Unicode 注入（不受对方输入法影响，中文也能直接打）。
  // ⚠️ Ctrl/Alt 组合时 Flutter 给的 character 会是控制字符（Ctrl+C → \x03）
  // 甚至 null —— 那种情况**不能**按原样发出去，否则被控端收到一个不可见
  // 字符，组合键根本形不成。所以只对"真是可见字符"走这条路。
  final ch = character;
  if (ch != null && ch.isNotEmpty) {
    final unit = ch.codeUnitAt(0);
    if (unit >= 0x20 && unit != 0x7F) return RemoteKey(char: ch);
  }

  // 走到这里通常是 Ctrl+C 这类组合：换成虚拟键码发出去，
  // 让"Ctrl 已按下"这件事在被控端和这个按键叠加起来。
  final label = logical.keyLabel;
  if (label.length == 1) {
    // Win32 的 VK_A..VK_Z 正好等于大写字母的 ASCII，VK_0..VK_9 等于数字的
    // ASCII —— 所以 toUpperCase 之后取码就是答案，不必写 36 行对照表。
    // 长度必须为 1：'F1'、'Tab' 这种多字符标签取首字母会推导出错误的键。
    final c = label.toUpperCase().codeUnitAt(0);
    final isLetter = c >= 0x41 && c <= 0x5A;
    final isDigit = c >= 0x30 && c <= 0x39;
    if (isLetter || isDigit) return RemoteKey(vk: c);
  }

  if (logical == LogicalKeyboardKey.space) return const RemoteKey(vk: Vk.space);
  return null;
}

/// F1..F12 对照表。远程排障时 F5（刷新）/ F2（改名）这类很常用，
/// 不映射的话按下去对面毫无反应，而用户只会以为"这软件不支持功能键"。
// ⚠️ 不用 `const`：LogicalKeyboardKey 重写了 == / hashCode，Dart 不允许它
// 出现在常量 map 的键位置（那种 map 的查找语义会变得不可预期）。
final Map<LogicalKeyboardKey, int> _fKeys = <LogicalKeyboardKey, int>{
  LogicalKeyboardKey.f1: Vk.f1,
  LogicalKeyboardKey.f2: Vk.f1 + 1,
  LogicalKeyboardKey.f3: Vk.f1 + 2,
  LogicalKeyboardKey.f4: Vk.f1 + 3,
  LogicalKeyboardKey.f5: Vk.f1 + 4,
  LogicalKeyboardKey.f6: Vk.f1 + 5,
  LogicalKeyboardKey.f7: Vk.f1 + 6,
  LogicalKeyboardKey.f8: Vk.f1 + 7,
  LogicalKeyboardKey.f9: Vk.f1 + 8,
  LogicalKeyboardKey.f10: Vk.f1 + 9,
  LogicalKeyboardKey.f11: Vk.f1 + 10,
  LogicalKeyboardKey.f12: Vk.f12,
};

class RemoteControlScreen extends StatefulWidget {
  const RemoteControlScreen({super.key});

  @override
  State<RemoteControlScreen> createState() => _RemoteControlScreenState();
}

class _RemoteControlScreenState extends State<RemoteControlScreen> {
  final _svc = RemoteAssistService.instance;
  final FocusNode _focus = FocusNode();
  bool _ctrlMode = true;

  @override
  void initState() {
    super.initState();
    Future<void>.delayed(const Duration(milliseconds: 200), () {
      if (mounted) FocusScope.of(context).requestFocus(_focus);
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  // ---- 指针 ----

  void _onHover(PointerHoverEvent e, BoxConstraints box) {
    if (!_ctrlMode) return;
    _svc.sendPointer(_nx(e.localPosition, box), _ny(e.localPosition, box));
  }

  void _onDown(PointerDownEvent e, BoxConstraints box) {
    if (!_ctrlMode) return;
    _svc.sendPointer(_nx(e.localPosition, box), _ny(e.localPosition, box));
    _svc.sendMouseDown(_btnOf(e.buttons));
  }

  void _onUp(PointerUpEvent e, BoxConstraints box) {
    if (!_ctrlMode) return;
    _svc.sendMouseUp(_btnOf(e.buttons));
  }

  void _onWheel(PointerScrollEvent e, BoxConstraints box) {
    if (!_ctrlMode) return;
    // 浏览器/触控板的滚动量通常是 100 上下，这里折成一格
    final step = e.scrollDelta.dy > 0 ? -1 : 1;
    _svc.sendWheel(step);
  }

  double _nx(Offset p, BoxConstraints box) =>
      (p.dx / box.maxWidth).clamp(0.0, 1.0);
  double _ny(Offset p, BoxConstraints box) =>
      (p.dy / box.maxHeight).clamp(0.0, 1.0);

  RemoteMouseButton _btnOf(int buttons) {
    if (buttons & kSecondaryButton != 0) return RemoteMouseButton.right;
    if (buttons & kTertiaryButton != 0) return RemoteMouseButton.middle;
    return RemoteMouseButton.left;
  }

  // ---- 键盘 ----

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (!_ctrlMode) return KeyEventResult.ignored;
    // 修饰键本身不需要转换：Windows 端按 host 当前状态处理即可，
    // 真正的组合效果（Ctrl+C）由 host 侧的按键序列自然形成。
    final k = _keyOf(e.logicalKey, e.character);
    if (k == null) return KeyEventResult.ignored;
    if (e is KeyDownEvent) {
      _svc.sendKeyDown(k);
    } else if (e is KeyUpEvent) {
      _svc.sendKeyUp(k);
    }
    return KeyEventResult.handled;
  }

  RemoteKey? _keyOf(LogicalKeyboardKey logical, String? character) =>
      remoteKeyOf(logical, character);

  @override
  Widget build(BuildContext context) {
    final svc = _svc;
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: ValueListenableBuilder<RemotePhase>(
          valueListenable: svc.phase,
          builder: (_, p, __) {
            return Column(children: [
              _ControlBar(
                ctrlMode: _ctrlMode,
                onToggle: (v) => setState(() => _ctrlMode = v),
              ),
              Expanded(
                child: Center(
                  child: LayoutBuilder(builder: (_, box) {
                    return Listener(
                      onPointerHover: (e) => _onHover(e, box),
                      onPointerDown: (e) => _onDown(e, box),
                      onPointerUp: (e) => _onUp(e, box),
                      onPointerSignal: (sig) {
                        if (sig is PointerScrollEvent) _onWheel(sig, box);
                      },
                      child: Focus(
                        focusNode: _focus,
                        onKeyEvent: _onKey,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            RTCVideoView(
                              svc.remoteRenderer,
                              objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                            ),
                            if (p != RemotePhase.active)
                              Container(
                                color: Colors.black54,
                                alignment: Alignment.center,
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (p != RemotePhase.ended)
                                      const SizedBox(
                                        width: 26, height: 26,
                                        child: CircularProgressIndicator(strokeWidth: 2),
                                      ),
                                    const SizedBox(height: 14),
                                    Text(
                                      p == RemotePhase.ended
                                          ? '会话已结束'
                                          : _phaseText(p),
                                      style: const TextStyle(color: Colors.white, fontSize: 14),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  }),
                ),
              ),
              _DiagBar(),
            ]);
          },
        ),
      ),
    );
  }
}

class _ControlBar extends StatelessWidget {
  const _ControlBar({required this.ctrlMode, required this.onToggle});
  final bool ctrlMode;
  final ValueChanged<bool> onToggle;

  @override
  Widget build(BuildContext context) {
    final svc = RemoteAssistService.instance;
    return Container(
      color: AppColors.bgElevated,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(children: [
        IconButton(
          icon: const Icon(Icons.close_rounded, color: AppColors.textSub),
          tooltip: '断开连接',
          onPressed: () async {
            await svc.hangUp();
            if (context.mounted) Navigator.of(context).maybePop();
          },
        ),
        Expanded(
          child: ValueListenableBuilder<RemoteSession?>(
            valueListenable: svc.session,
            builder: (_, s, __) => Text(
              s == null ? '远程协助' : '正在协助 ${s.hostName}',
              style: const TextStyle(fontSize: 13.5),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        Row(children: [
          const Text('允许控制', style: TextStyle(fontSize: 12)),
          Switch(
            value: ctrlMode,
            onChanged: onToggle,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        ]),
      ]),
    );
  }
}

class _DiagBar extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final svc = RemoteAssistService.instance;
    return ValueListenableBuilder<String>(
      valueListenable: svc.diag,
      builder: (_, d, __) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        color: AppColors.bgElevated,
        child: Text(
          d.isEmpty ? '准备就绪' : d,
          style: const TextStyle(fontSize: 11.5, color: AppColors.textWeak),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
  }
}

// ============================================================ 被控端 UI

/// 被控端常驻警示条。
///
/// 【为什么必须常驻且醒目】
/// 这是远程协助里唯一能防止"被悄悄控住"的东西。只要会话没结束，用户
/// 就应该随时能在余光里看到它 —— 做成能顺手关掉的通知就失去意义了。
class RemoteHostBanner extends StatelessWidget {
  const RemoteHostBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final svc = RemoteAssistService.instance;
    return ValueListenableBuilder<RemotePhase>(
      valueListenable: svc.phase,
      builder: (_, p, __) {
        if (!svc.isHost || p != RemotePhase.active) return const SizedBox.shrink();
        final s = svc.session.value;
        return Container(
          width: double.infinity,
          color: AppColors.warn.withValues(alpha: 0.16),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(children: [
            const Icon(Icons.screen_share_rounded, size: 17, color: AppColors.warn),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '正在被「${s?.controllerName ?? '对方'}」远程协助 —— 你的屏幕正在共享',
                style: const TextStyle(fontSize: 12.5, color: AppColors.warn),
              ),
            ),
            TextButton(
              onPressed: () => svc.hangUp(),
              child: const Text('立即断开', style: TextStyle(color: AppColors.danger, fontSize: 12.5)),
            ),
          ]),
        );
      },
    );
  }
}

/// 收到协助请求时的确认弹窗（有人值守 / 无人值守都在窗口里给选择）
Future<void> showRemoteRequestDialog(BuildContext context) async {
  final svc = RemoteAssistService.instance;
  final s = svc.session.value;
  if (s == null) return;

  final injector = createInputInjector();
  final canControl = injector.supported;

  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) {
      return _RemoteRequestSheet(
        name: s.controllerName,
        unattended: s.unattended,
        canControl: canControl,
        injectHint: injector.hint,
        deadline: s.abortDeadline,
      );
    },
  );
}

class _RemoteRequestSheet extends StatefulWidget {
  const _RemoteRequestSheet({
    required this.name,
    required this.unattended,
    required this.canControl,
    required this.injectHint,
    this.deadline,
  });

  final String name;
  final bool unattended;
  final bool canControl;
  final String injectHint;
  final DateTime? deadline;

  @override
  State<_RemoteRequestSheet> createState() => _RemoteRequestSheetState();
}

class _RemoteRequestSheetState extends State<_RemoteRequestSheet> {
  Timer? _t;
  int _left = 0;

  @override
  void initState() {
    super.initState();
    final d = widget.deadline;
    if (d != null) {
      _tick();
      _t = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    }
  }

  void _tick() {
    final d = widget.deadline;
    if (d == null) return;
    final left = d.difference(DateTime.now()).inSeconds;
    if (!mounted) return;
    setState(() => _left = left > 0 ? left : 0);
    if (left <= 0) {
      // 无人值守窗口结束：服务端会自动放行，这里只是关掉弹窗
      _t?.cancel();
      Navigator.of(context).maybePop();
    }
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final svc = RemoteAssistService.instance;
    return AlertDialog(
      backgroundColor: AppColors.bgElevated,
      title: Text(widget.unattended ? '有人用你的访问码发起连接' : '有人请求远程协助你'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('发起方：${widget.name}', style: const TextStyle(fontSize: 14)),
          const SizedBox(height: 12),
          Text(
            '同意后对方将看到你的屏幕'
            '${widget.canControl ? '，并且可以操作你的鼠标键盘' : '（此设备不支持远程控制，对方只能看）'}。',
            style: const TextStyle(fontSize: 13, color: AppColors.textSub, height: 1.6),
          ),
          if (!widget.canControl) ...[
            const SizedBox(height: 8),
            Text(widget.injectHint,
                style: const TextStyle(fontSize: 12, color: AppColors.warn, height: 1.5)),
          ],
          if (widget.unattended && _left > 0) ...[
            const SizedBox(height: 12),
            Text(
              '$_left 秒后自动同意（无人值守）。不想被连就点拒绝。',
              style: const TextStyle(fontSize: 12.5, color: AppColors.warn),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            svc.rejectAsHost();
            Navigator.of(context).pop();
          },
          child: const Text('拒绝', style: TextStyle(color: AppColors.danger)),
        ),
        FilledButton(
          onPressed: () {
            svc.acceptAsHost();
            Navigator.of(context).pop();
          },
          child: const Text('同意'),
        ),
      ],
    );
  }
}

// ============================================================ 小组件

class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
      ),
      child: child,
    );
  }
}

/// 给最高层的壳用：会话请求来了要弹窗，被控了要挂警示条。
///
/// 单独抽出来的原因是这两件事都必须在"任何页面之上"发生 ——
/// 不能因为用户在聊天页就不给他弹协作请求。
class RemoteAssistWatcher extends StatefulWidget {
  const RemoteAssistWatcher({required this.child, super.key});
  final Widget child;

  @override
  State<RemoteAssistWatcher> createState() => _RemoteAssistWatcherState();
}

class _RemoteAssistWatcherState extends State<RemoteAssistWatcher> {
  final _svc = RemoteAssistService.instance;

  @override
  void initState() {
    super.initState();
    _svc.start();
    _svc.session.addListener(_onSession);
    _svc.phase.addListener(_onPhase);
  }

  void _onSession() => _maybeShowSheet();

  void _onPhase() {
    const idle = RemotePhase.idle;
    const req = RemotePhase.requesting;
    // host 收到请求 → 弹确认框
    if (_svc.isHost && _svc.phase.value == req) {
      _maybeShowSheet();
      return;
    }
    if (_svc.phase.value == idle) return;
  }

  void _maybeShowSheet() {
    if (!_svc.isHost) return;
    if (_svc.phase.value != RemotePhase.requesting) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_svc.phase.value != RemotePhase.requesting) return;
      unawaited(showRemoteRequestDialog(context));
    });
  }

  @override
  void dispose() {
    _svc.session.removeListener(_onSession);
    _svc.phase.removeListener(_onPhase);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const RemoteHostBanner(),
        Expanded(child: widget.child),
      ],
    );
  }
}

double clampRatio(double v) => math.min(1.0, math.max(0.0, v));
