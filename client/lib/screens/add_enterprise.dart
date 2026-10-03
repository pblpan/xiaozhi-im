import 'package:flutter/material.dart';
import 'package:xiaozhi_im_client/api.dart';
import 'package:xiaozhi_im_client/core/config.dart';
import 'package:xiaozhi_im_client/core/discover.dart';
import 'package:xiaozhi_im_client/core/server_profile.dart';
import 'package:xiaozhi_im_client/core/session_manager.dart';
import 'package:xiaozhi_im_client/core/theme.dart';
import 'package:xiaozhi_im_client/widgets/avatar.dart';
import 'package:xiaozhi_im_client/widgets/gradient_button.dart';

/// 添加一家新企业（龙哥 2026-10-01 需求）。
///
/// 流程：① 填这台服务器的内网/外网地址（或局域网扫描）→ ② 在该服务器上登录/注册账号 →
/// 成功后落成一条独立的 [ServerProfile] 并**立即切过去**（整域切换）。
///
/// 与旧单租户登录的关键差异：登录时**先把全局 Config 临时指向新服务器**、用
/// [ImApi.loginRaw]/[ImApi.registerRaw]（不写全局 token）拿回 token，
/// 再交给 [SessionManager.addProfile] 落成档案——绝不让新服务器的登录态污染当前企业。
class AddEnterpriseScreen extends StatefulWidget {
  const AddEnterpriseScreen({super.key});

  @override
State<AddEnterpriseScreen> createState() => _AddEnterpriseScreenState();
}

class _AddEnterpriseScreenState extends State<AddEnterpriseScreen> {
  final _name = TextEditingController();
  final _lan = TextEditingController();
  final _wan = TextEditingController();
  final _u = TextEditingController();
  final _p = TextEditingController();
  final _n = TextEditingController();
  String _mode = Config.modeAuto;
  bool _step = false; // false=服务器, true=登录
  bool _reg = false; // false=登录, true=注册
  bool _load = false;
  bool _scanning = false;
  bool _probing = false;
  List<DiscoveredServer> _servers = const [];
  String? _err;

  @override
  void dispose() {
    _name.dispose();
    _lan.dispose();
    _wan.dispose();
    _u.dispose();
    _p.dispose();
    _n.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    setState(() {
      _scanning = true;
      _servers = const [];
      _err = null;
    });
    try {
      final found = await LanDiscover.scan();
      if (!mounted) return;
      setState(() {
        _servers = found;
        _scanning = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _err = '扫描失败（本机可能不允许 UDP 广播），可手动填写。';
      });
    }
  }

  void _adopt(DiscoveredServer s) {
    _lan.text = s.url;
    if (_name.text.trim().isEmpty) {
      _name.text = s.companyName.trim().isEmpty ? '小智' : s.companyName.trim();
    }
  }

  Future<void> _testAndNext() async {
    if (_lan.text.trim().isEmpty) {
      setState(() => _err = '内网地址不能为空');
      return;
    }
    setState(() {
      _probing = true;
      _err = null;
    });
    try {
      await ImApi.testServer(Config.normalize(_lan.text));
      if (!mounted) return;
      setState(() {
        _probing = false;
        _step = true;
        if (_name.text.trim().isEmpty) _name.text = '小智';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _probing = false;
        _err = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  void _back() => setState(() {
        _step = false;
        _err = null;
      });

  Future<void> _submit() async {
    if (_u.text.trim().isEmpty || _p.text.isEmpty) {
      setState(() => _err = '请填写账号和密码');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _load = true;
      _err = null;
    });
    final lan = Config.normalize(_lan.text);
    final wan =
        _wan.text.trim().isEmpty ? '' : Config.normalize(_wan.text);
    final name = _name.text.trim().isEmpty ? '小智' : _name.text.trim();
    final savedActive = SessionManager.instance.active;
    // 临时把全局 Config 指向新服务器，登录请求才能打到它
    Config.lanUrl = lan;
    Config.wanUrl = wan;
    Config.mode = _mode;
    await Config.resolveNow();
    try {
      final nick = _n.text.trim().isEmpty ? _u.text.trim() : _n.text.trim();
      final d = _reg
          ? await ImApi().registerRaw(_u.text.trim(), _p.text, nick)
          : await ImApi().loginRaw(_u.text.trim(), _p.text);
      final token = (d['token'] as String?) ?? '';
      if (token.isEmpty) throw const ApiException('服务器未返回登录凭证');
      final profile = ServerProfile(
        id: ServerProfile.newId(),
        name: name,
        lan: lan,
        wan: wan,
        mode: _mode,
        token: token,
      );
      // addProfile(makeActive:true)：把全局 Config 切回这家新企业 + token 写 Storage
      // + 重连 WS + emit domainVersion（后台连接与各页面重载都跟着走）。
      // 不用手动再 setToken——ImApi._h 永远读「激活档案」的 token。
      await SessionManager.instance.addProfile(profile, makeActive: true);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      // 失败：把全局 Config 还原回原激活企业，别让界面停在连着新服务器的状态
      if (savedActive != null) {
        Config.lanUrl = savedActive.lan;
        Config.wanUrl = savedActive.wan;
        Config.mode = savedActive.mode;
        await Config.resolveNow();
      }
      await ImApi().restore();
      if (mounted) {
        setState(() {
          _load = false;
          _err = e.toString().replaceFirst('Exception: ', '');
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          leading: _step
              ? IconButton(
                  icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
                  onPressed: _back,
                )
              : null,
          title: const Text('添加企业'),
        ),
        body: Container(
          decoration: const BoxDecoration(gradient: AppTheme.bgGradient),
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
                  decoration: BoxDecoration(
                    color: AppColors.bgElevated,
                    borderRadius: BorderRadius.circular(AppRadii.xl),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: _step ? _authView() : _serverView(),
                ),
              ),
            ),
          ),
        ),
      );

  Widget _serverView() => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Center(child: BrandLogo(size: 52)),
          const SizedBox(height: 14),
          const Center(
            child: Text('连接新企业的服务器',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(height: 22),
          const _Label('企业名称（界面上显示，如「B小智」）'),
          const SizedBox(height: 6),
          _field(_name, 'B小智', Icons.business_rounded),
          const SizedBox(height: 16),
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
            onSelectionChanged: (s) => setState(() => _mode = s.first),
          ),
          const SizedBox(height: 16),
          const _Label('内网地址（必填）'),
          const SizedBox(height: 6),
          _field(_lan, '192.168.1.10:3602', Icons.wifi_rounded),
          const SizedBox(height: 14),
          const _Label('外网地址（出差/在家，选填）'),
          const SizedBox(height: 6),
          _field(_wan, 'https://your-domain.example.com', Icons.public_rounded),
          const SizedBox(height: 16),
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
              side: const BorderSide(color: AppColors.border),
              padding: const EdgeInsets.symmetric(vertical: 10),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppRadii.sm)),
            ),
          ),
          for (final s in _servers)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: InkWell(
                borderRadius: BorderRadius.circular(AppRadii.sm),
                onTap: () => _adopt(s),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(AppRadii.sm),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.dns_rounded,
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
                              Text('公司：${s.companyName}',
                                  style: const TextStyle(
                                      fontSize: 11,
                                      color: AppColors.textWeak)),
                          ],
                        ),
                      ),
                      const Icon(Icons.check_rounded,
                          size: 16, color: AppColors.textWeak),
                    ],
                  ),
                ),
              ),
            ),
          if (_err != null) _errorBox(_err!),
          const SizedBox(height: 18),
          GradientButton(
            text: _probing ? '测试中…' : '下一步',
            loading: _probing,
            onPressed: _probing ? null : _testAndNext,
          ),
        ],
      );

  Widget _authView() => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Center(child: BrandLogo(size: 48)),
          const SizedBox(height: 12),
          Center(
            child: Text(_name.text,
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          ),
          const SizedBox(height: 4),
          Center(
            child: Text('在「${_lan.text}」上登录账号',
                style:
                    const TextStyle(color: AppColors.textSub, fontSize: 12.5)),
          ),
          const SizedBox(height: 18),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('登录')),
              ButtonSegment(value: true, label: Text('注册')),
            ],
            selected: {_reg},
            onSelectionChanged: (s) => setState(() => _reg = s.first),
          ),
          const SizedBox(height: 16),
          _field(_u, '账号', Icons.person_outline_rounded),
          const SizedBox(height: 12),
          if (_reg)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _field(_n, '昵称（选填）', Icons.badge_outlined),
                const SizedBox(height: 12),
              ],
            ),
          _field(_p, '密码', Icons.lock_outline_rounded, obscure: true),
          if (_err != null) _errorBox(_err!),
          const SizedBox(height: 22),
          GradientButton(
            text: _reg ? '注册并登录' : '登录并切换',
            loading: _load,
            onPressed: _load ? null : _submit,
          ),
        ],
      );

  Widget _field(TextEditingController c, String hint, IconData icon,
          {bool obscure = false}) =>
      TextField(
        controller: c,
        obscureText: obscure,
        style: const TextStyle(fontSize: 14, fontFamily: 'monospace'),
        decoration: InputDecoration(
          hintText: hint,
          prefixIcon: Icon(icon, size: 18, color: AppColors.textWeak),
        ),
      );

  Widget _errorBox(String msg) => Container(
        margin: const EdgeInsets.only(bottom: 14, top: 12),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.danger.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(AppRadii.sm),
          border: Border.all(color: AppColors.danger.withValues(alpha: 0.35)),
        ),
        child: Row(
          children: [
            const Icon(Icons.error_outline, size: 17, color: AppColors.danger),
            const SizedBox(width: 8),
            Expanded(
              child: Text(msg,
                  style:
                      const TextStyle(color: AppColors.danger, fontSize: 13)),
            ),
          ],
        ),
      );
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
