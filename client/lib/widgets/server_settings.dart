import 'package:flutter/material.dart';
import 'package:xiaozhi_im_client/api.dart';
import 'package:xiaozhi_im_client/core/config.dart';
import 'package:xiaozhi_im_client/core/settings.dart';
import 'package:xiaozhi_im_client/core/theme.dart';

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
    await Settings.setServers(lan: lan, wan: wan, mode: _mode);
    // 保存后强制重探一次，让右上角当前地址立刻生效
    await Config.resolveNow();
    if (mounted) Navigator.pop(context, true);
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
                  style: const TextStyle(
                      fontSize: 11.5, color: AppColors.textWeak),
                ),

                const SizedBox(height: 18),
                _AddrField(
                  label: '内网地址',
                  hint: '192.168.31.44:3602',
                  ctrl: _lanCtrl,
                  icon: Icons.wifi_rounded,
                  status: _lanStatus,
                ),
                const SizedBox(height: 14),
                _AddrField(
                  label: '外网地址',
                  hint: 'https://xxxx.hn.takin.cc',
                  ctrl: _wanCtrl,
                  icon: Icons.public_rounded,
                  status: _wanStatus,
                ),

                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        '当前使用：${Config.baseUrl}',
                        style: const TextStyle(
                            fontSize: 11.5,
                            color: AppColors.textWeak,
                            fontFamily: 'monospace'),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        _lanCtrl.text = Config.builtInBaseUrl;
                      },
                      child: const Text('内网填内置', style: TextStyle(fontSize: 12)),
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
                    side: const BorderSide(color: AppColors.border),
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
        style: const TextStyle(
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
            helperStyle: const TextStyle(
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