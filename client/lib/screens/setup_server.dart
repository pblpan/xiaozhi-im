import 'package:flutter/material.dart';

import '../core/config.dart';
import '../core/discover.dart';
import '../core/settings.dart';
import '../core/theme.dart';
import '../widgets/avatar.dart';
import '../widgets/server_settings.dart';

/// 首次使用：App 还不知道该连哪台服务器。
///
/// 【为什么需要这个页面】
/// 客户端加固（2026-09-16）之后，安装包里**不再内置任何生产地址** ——
/// 客户拿去连的是他自己的服务器。于是"新装 + 局域网没应答"成了一个真实状态：
/// 可能是服务器没开、不在同一网段、或者路由器拦了 UDP 广播。
///
/// 不处理这个状态的后果很具体：用户停在登录页反复点登录，只看到"网络错误"，
/// 完全不知道下一步该干什么（他没有"服务器设置"这个概念）。
/// 所以这里给出唯一出口：**一键局域网发现** + **手填地址**。
///
/// 只要局域网里有一台小智服务器（UDP 3616 在应答），用户点一下就进去了。
class SetupServerScreen extends StatefulWidget {
  /// 配好服务器后的回调（调用方据此重新判断该去登录页还是主界面）
  final VoidCallback onConfigured;

  const SetupServerScreen({super.key, required this.onConfigured});

  @override
  State<SetupServerScreen> createState() => _SetupServerScreenState();
}

class _SetupServerScreenState extends State<SetupServerScreen> {
  bool _scanning = false;
  List<DiscoveredServer> _servers = const [];
  String? _note;

  @override
  void initState() {
    super.initState();
    // 进页面自动扫一次：绝大多数人这一步就能把事办了，不用再点按钮
    WidgetsBinding.instance.addPostFrameCallback((_) => _scan());
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _servers = const [];
      _note = null;
    });
    try {
      final found = await LanDiscover.scan();
      if (!mounted) return;
      setState(() {
        _servers = found;
        _scanning = false;
        _note = found.isEmpty
            ? '没扫到服务器。请确认本机与服务器连的是同一个路由器；'
                '也可以直接手填服务器地址。'
            : null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _note = '扫描失败（本机可能不允许 UDP 广播），可直接手填服务器地址。';
      });
    }
  }

  /// 采用扫描到的这一台。
  /// 走 Settings.setServers 而不是直接改 Config —— 这样地址会落盘，
  /// 下次启动不用再扫（同时意味着"用户配过了"，管理台下发的候选不再覆盖它，
  /// 这是有意的：用户明确选了哪台，就该听用户的）。
  Future<void> _adopt(DiscoveredServer s) async {
    await Settings.setServers(lan: s.url, wan: '', mode: Config.modeAuto);
    await Config.resolveNow();
    if (!mounted) return;
    widget.onConfigured();
  }

  Future<void> _manual() async {
    final changed = await showServerSettings(context);
    if (!mounted) return;
    if (changed == true) widget.onConfigured();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bg,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Center(child: BrandLogo(size: 64)),
                const SizedBox(height: 20),
                const Text(
                  '连接你的服务器',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w600,
                    color: AppColors.text,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  '小智 IM 需要一台服务器（公司电脑或 NAS）才能收发消息。\n'
                  '如果它和本机在同一个网络里，下面会自动找出来。',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 13, height: 1.6, color: AppColors.textSub),
                ),
                const SizedBox(height: 24),

                // ---- 发现结果 ----
                if (_scanning)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 14),
                    child: Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  ),
                if (_scanning)
                  const Text('正在扫描局域网…',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          fontSize: 12.5, color: AppColors.textWeak)),

                for (final s in _servers)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _ServerTile(
                      server: s,
                      onTap: () => _adopt(s),
                    ),
                  ),

                if (_note != null)
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(AppRadii.sm),
                      border: Border.all(color: AppColors.border),
                    ),
                    child: Text(
                      _note!,
                      style: const TextStyle(
                          fontSize: 12, height: 1.6, color: AppColors.textSub),
                    ),
                  ),

                const SizedBox(height: 18),
                OutlinedButton.icon(
                  onPressed: _scanning ? null : _scan,
                  icon: const Icon(Icons.radar_rounded, size: 17),
                  label: Text(_scanning ? '扫描中…' : '重新扫描局域网',
                      style: const TextStyle(fontSize: 13.5)),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppColors.brand,
                    side: const BorderSide(color: AppColors.border),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadii.sm)),
                  ),
                ),
                const SizedBox(height: 10),
                TextButton.icon(
                  onPressed: _manual,
                  icon: const Icon(Icons.edit_rounded, size: 16),
                  label: const Text('手动填写服务器地址',
                      style: TextStyle(fontSize: 13)),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.textSub,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 扫描到的一台服务器：点一下就用它。
/// 显示公司名 / 版本是为了让"同一网段有好几台"时能选对 ——
/// 这也是把名字和版本一起发现回来的原因。
class _ServerTile extends StatelessWidget {
  final DiscoveredServer server;
  final VoidCallback onTap;

  const _ServerTile({required this.server, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final name = server.companyName.trim();
    return Material(
      color: AppColors.surface,
      borderRadius: BorderRadius.circular(AppRadii.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadii.md),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              const Icon(Icons.dns_rounded,
                  size: 20, color: AppColors.brand),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name.isEmpty ? '小智 IM 服务器' : name,
                      style: const TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                          color: AppColors.text),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Text(
                      server.url +
                          (server.serverVersion.isEmpty
                              ? ''
                              : '  ·  v${server.serverVersion}'),
                      style: const TextStyle(
                          fontSize: 12,
                          fontFamily: 'monospace',
                          color: AppColors.textWeak),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded,
                  size: 20, color: AppColors.textWeak),
            ],
          ),
        ),
      ),
    );
  }
}
