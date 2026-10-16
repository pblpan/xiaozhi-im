import 'package:flutter/material.dart';
import 'package:xiaozhi_im_client/api.dart';
import 'package:xiaozhi_im_client/core/config.dart';
import 'package:xiaozhi_im_client/core/discover.dart';
import 'package:xiaozhi_im_client/core/remote_config.dart';
import 'package:xiaozhi_im_client/core/settings.dart';
import 'package:xiaozhi_im_client/core/theme.dart';
import 'package:xiaozhi_im_client/core/workspace.dart';
import 'package:xiaozhi_im_client/widgets/enterprise_switcher.dart';

/// 服务器设置弹窗（双地址 + 网络模式 + 自动探测）。
///
/// 返回 true 表示地址/模式被修改（调用方需处理重连 / 重新登录）。
Future<bool?> showServerSettings(BuildContext context) {
  return showDialog<bool>(
    context: context,
    builder: (d) => _ServerSettingsDialog(initialMode: Config.mode),
  );
}

class _ServerSettingsDialog extends StatefulWidget {
  final String initialMode;
  const _ServerSettingsDialog({required this.initialMode});

  @override
  State<_ServerSettingsDialog> createState() => _ServerSettingsDialogState();
}

class _ServerSettingsDialogState extends State<_ServerSettingsDialog> {
  late final TextEditingController _lanCtrl;
  late final TextEditingController _wanCtrl;
  late String _mode;

  // 探测状态
  String? _lanStatus; // null | 'ok' | 'fail:<msg>'
  String? _wanStatus;
  bool _probing = false;

  // 局域网扫描状态
  bool _scanning = false;
  List<DiscoveredServer> _scanned = const [];
  String? _scanNote; // 扫描结果说明（没扫到/失败原因）

  // 「从服务器获取推荐地址」状态
  bool _fetchingRec = false;
  String? _recNote;

  @override
  void initState() {
    super.initState();
    _lanCtrl = TextEditingController(text: Config.lanUrl);
    _wanCtrl = TextEditingController(text: Config.wanUrl);
    _mode = widget.initialMode;
  }

  @override
  void dispose() {
    _lanCtrl.dispose();
    _wanCtrl.dispose();
    super.dispose();
  }

  Future<void> _probeAll() async {
    setState(() {
      _probing = true;
      _lanStatus = null;
      _wanStatus = null;
    });
    final futures = <Future<void>>[];
    if (_lanCtrl.text.trim().isNotEmpty) {
      futures.add(_probeAddr(Config.normalize(_lanCtrl.text), isLan: true));
    }
    if (_wanCtrl.text.trim().isNotEmpty) {
      futures.add(_probeAddr(Config.normalize(_wanCtrl.text), isLan: false));
    }
    await Future.wait(futures);
    if (mounted) setState(() => _probing = false);
  }

  Future<void> _probeAddr(String url, {required bool isLan}) async {
    try {
      await ImApi.testServer(url);
      if (mounted) {
        setState(() => isLan ? _lanStatus = 'ok' : _wanStatus = 'ok');
      }
    } catch (e) {
      if (mounted) {
        final msg = e.toString().replaceFirst('Exception: ', '');
        setState(() => isLan
            ? _lanStatus = 'fail:$msg'
            : _wanStatus = 'fail:$msg');
      }
    }
  }

  /// 局域网扫描：UDP 广播问一圈"谁是内网 IM 服务器"。
  /// 扫到 → 列表展示，点一条直接填入内网地址框；
  /// 扫不到 → 给出说明（服务器可能不在这个网段 / 不支持发现），引导手填。
  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _scanned = const [];
      _scanNote = null;
    });
    try {
      final found = await LanDiscover.scan();
      if (!mounted) return;
      setState(() {
        _scanned = found;
        _scanning = false;
        _scanNote = found.isEmpty ? '没发现服务器：请确认手机/电脑与服务器连的是同一个路由器' : null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _scanNote = '扫描失败，可直接手填内网地址';
      });
    }
  }

  /// 从服务器拿推荐地址（bootstrap 的 serverAddresses，管理台配的最新候选），
  /// 填进两个输入框 —— 只填不存，用户看得见改了什么，点保存才生效。
  /// 场景：老设备手动配过地址后不再跟随下发，服务器换地址（如外网隧道
  /// 从 takin.cc 换成云服务器）时用它一键追平。
  Future<void> _applyRecommended() async {
    setState(() {
      _fetchingRec = true;
      _recNote = null;
    });
    final pub = await RemoteConfig.fetchPublic();
    if (!mounted) return;
    setState(() => _fetchingRec = false);
    final pl = pub['payload'];
    final raw = pl is Map ? pl['serverAddresses'] : null;
    final list = raw is List
        ? raw.whereType<String>().where((s) => s.trim().isNotEmpty).toList()
        : const <String>[];
    if (list.isEmpty) {
      setState(() => _recNote = '没拿到推荐地址：请先连上任意一台服务器再试');
      return;
    }
    setState(() {
      _lanCtrl.text = list[0];
      if (list.length > 1) _wanCtrl.text = list[1];
      _recNote = '已填入服务端最新推荐（共 ${list.length} 条），确认后点保存';
    });
  }

  Future<void> _save() async {
    final lan = Config.normalize(_lanCtrl.text);
    final wan = _wanCtrl.text.trim().isEmpty
        ? ''
        : Config.normalize(_wanCtrl.text);
    if (lan.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('内网地址不能为空')),
      );
      return;
    }
    // 🔴 失败必须喊出来（龙哥 2026-10-13：全新安装点保存"毫无反应"，
    //    排查半天才发现是 addProfile 对 const 列表抛了没人接的异常）。
    //    静默失败是最难查的一类 bug —— 弹窗别关，把原因亮在脸上。
    try {
      await Settings.setServers(lan: lan, wan: wan, mode: _mode);
      // 保存后强制重探一次，让右上角当前地址立刻生效
      await Config.resolveNow();
      // 地址变了：重新拉服务器模式（工作/普通），导航形态可能要跟着变
      Workspace.refresh();
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('保存失败：$e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 4),
        contentPadding: const EdgeInsets.fromLTRB(20, 6, 20, 4),
        title: const Row(
          children: [
            Icon(Icons.dns_rounded, size: 20),
            SizedBox(width: 8),
            Text('服务器设置'),
          ],
        ),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // 🔴 连接状态：从首页顶条挪过来的（龙哥 2026-10-06 真机截图反馈）。
                //    首页顶上那条「● 已连接 ∨」跟会话页 AppBar 的连接点是重复信息，
                //    还把整个界面往下顶；而排查"连不上"的时候人正好就在这个弹窗里，
                //    所以把状态放到这里 —— 打开服务器设置就能看到当前通不通。
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 9),
                  decoration: BoxDecoration(
                    color: AppColors.bgElevated,
                    borderRadius: BorderRadius.circular(AppRadii.md),
                    border: Border.all(color: AppColors.divider),
                  ),
                  child:  Row(
                    children: [
                      Text('当前连接',
                          style: TextStyle(
                              fontSize: 12.5, color: AppColors.textSub)),
                      Spacer(),
                      ConnStatusChip(dotSize: 9, fontSize: 12.5),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                // 网络模式
                const _Label('网络模式'),
                const SizedBox(height: 6),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(
                      value: Config.modeAuto,
                      label: Text('自动'),
                      icon: Icon(Icons.auto_mode_rounded, size: 16),
                    ),
                    ButtonSegment(
                      value: Config.modeLan,
                      label: Text('内网'),
                      icon: Icon(Icons.wifi_rounded, size: 16),
                    ),
                    ButtonSegment(
                      value: Config.modeWan,
                      label: Text('外网'),
                      icon: Icon(Icons.public_rounded, size: 16),
                    ),
                  ],
                  selected: {_mode},
                  onSelectionChanged: (s) =>
                      setState(() => _mode = s.first),
                ),
                const SizedBox(height: 4),
                Text(
                  _modeHint(_mode),
                  style:  TextStyle(
                      fontSize: 11.5, color: AppColors.textWeak),
                ),

                const SizedBox(height: 18),
                _AddrField(
                  label: '内网地址',
                  // 通用示例，不是任何真实服务器（加固后包里不含生产地址）
                  hint: '192.168.1.10:3602',
                  ctrl: _lanCtrl,
                  icon: Icons.wifi_rounded,
                  status: _lanStatus,
                ),
                const SizedBox(height: 14),
                _AddrField(
                  label: '外网地址',
                  hint: 'https://your-domain.example.com',
                  ctrl: _wanCtrl,
                  icon: Icons.public_rounded,
                  status: _wanStatus,
                ),

                const SizedBox(height: 18),
                OutlinedButton.icon(
                  onPressed: _scanning ? null : _scan,
                  icon: _scanning
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.radar_rounded, size: 16),
                  label: Text(_scanning ? '正在扫描局域网…' : '扫描内网服务器',
                      style: const TextStyle(fontSize: 13)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.brand,
                    side: BorderSide(color: AppColors.border),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadii.sm)),
                  ),
                ),
                // 扫描结果：点一条直接填入内网地址（仍可手改）
                for (final s in _scanned)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(AppRadii.sm),
                      onTap: () {
                        _lanCtrl.text = s.url;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                              content: Text('已填入：${s.url}（记得保存）'),
                              duration: const Duration(seconds: 2)),
                        );
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 9),
                        decoration: BoxDecoration(
                          color: AppColors.surface,
                          borderRadius: BorderRadius.circular(AppRadii.sm),
                          border: Border.all(color: AppColors.border),
                        ),
                        child: Row(
                          children: [
                             Icon(Icons.dns_rounded,
                                size: 16, color: AppColors.brand),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(s.url,
                                      style: const TextStyle(
                                          fontSize: 13,
                                          fontFamily: 'monospace',
                                          fontWeight: FontWeight.w600)),
                                  if (s.companyName.isNotEmpty)
                                    Text('公司：${s.companyName} · 服务端 v${s.serverVersion}',
                                        style:  TextStyle(
                                            fontSize: 11,
                                            color: AppColors.textWeak)),
                                ],
                              ),
                            ),
                             Icon(Icons.check_rounded,
                                size: 16, color: AppColors.textWeak),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (_scanNote != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(_scanNote!,
                        style:  TextStyle(
                            fontSize: 11.5, color: AppColors.textWeak)),
                  ),

                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: _fetchingRec ? null : _applyRecommended,
                  icon: _fetchingRec
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.cloud_download_rounded, size: 16),
                  label: const Text('从服务器获取推荐地址',
                      style: TextStyle(fontSize: 13)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.brand,
                    side: BorderSide(color: AppColors.border),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadii.sm)),
                  ),
                ),
                if (_recNote != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(_recNote!,
                        style:  TextStyle(
                            fontSize: 11.5, color: AppColors.textWeak)),
                  ),

                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        // 加固后"没有地址"是合法状态（新装没扫到服务器），
                        // 直接显示"当前使用："后面一片空白会让人以为界面坏了
                        Config.baseUrl.isEmpty
                            ? '未配置服务器（可扫描或手填）'
                            : '当前使用：${Config.baseUrl}',
                        style:  TextStyle(
                            fontSize: 11.5,
                            color: AppColors.textWeak,
                            fontFamily: 'monospace'),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    // 「填内置」只在**定制包**（构建时 --dart-define=BASE_URL 注入过）
                    // 才有意义；通用包内置值是空的，按钮就是死的 → 换成清空。
                    if (Config.builtInBaseUrl.isNotEmpty)
                      TextButton(
                        onPressed: () {
                          _lanCtrl.text = Config.builtInBaseUrl;
                        },
                        child: const Text('内网填内置',
                            style: TextStyle(fontSize: 12)),
                      )
                    else
                      TextButton(
                        onPressed: () => setState(() => _lanCtrl.clear()),
                        child: const Text('清空', style: TextStyle(fontSize: 12)),
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                OutlinedButton.icon(
                  onPressed: _probing ? null : _probeAll,
                  icon: _probing
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.wifi_tethering_rounded, size: 16),
                  label: const Text('测试两个地址'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.brand,
                    side: BorderSide(color: AppColors.border),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadii.sm)),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消')),
          FilledButton(
            onPressed: _save,
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.brand,
              foregroundColor: Colors.white,
            ),
            child: const Text('保存'),
          ),
        ],
      );

  static String _modeHint(String m) {
    switch (m) {
      case Config.modeLan:
        return '只用内网地址；外网设备无法连接';
      case Config.modeWan:
        return '只用外网地址；远程办公专用';
      default:
        return '启动时自动探测两个地址，先连通用谁';
    }
  }
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);
  @override
  Widget build(BuildContext context) => Text(
        text,
        style:  TextStyle(
          fontSize: 12,
          color: AppColors.textWeak,
          fontWeight: FontWeight.w500,
        ),
      );
}

class _AddrField extends StatelessWidget {
  final String label;
  final String hint;
  final TextEditingController ctrl;
  final IconData icon;
  final String? status; // null | 'ok' | 'fail:<msg>'
  const _AddrField({
    required this.label,
    required this.hint,
    required this.ctrl,
    required this.icon,
    required this.status,
  });

  @override
  Widget build(BuildContext context) {
    Color? suffixColor;
    IconData? suffixIcon;
    if (status == 'ok') {
      suffixColor = AppColors.online;
      suffixIcon = Icons.check_circle_outline_rounded;
    } else if (status != null && status!.startsWith('fail:')) {
      suffixColor = AppColors.danger;
      suffixIcon = Icons.error_outline_rounded;
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Label(label),
        const SizedBox(height: 6),
        TextField(
          controller: ctrl,
          style: const TextStyle(fontSize: 14, fontFamily: 'monospace'),
          decoration: InputDecoration(
            hintText: hint,
            helperText: status != null && status!.startsWith('fail:')
                ? status!.substring(5)
                : null,
            helperStyle:  TextStyle(
                fontSize: 11, color: AppColors.danger),
            prefixIcon: Icon(icon, size: 18, color: AppColors.textWeak),
            suffixIcon: suffixIcon != null
                ? Icon(suffixIcon, size: 18, color: suffixColor)
                : null,
          ),
        ),
      ],
    );
  }
}