import 'package:flutter/material.dart';
import 'package:xiaozhi_im_client/api.dart';
import 'package:xiaozhi_im_client/core/config.dart';
import 'package:xiaozhi_im_client/core/theme.dart';
import 'package:xiaozhi_im_client/screens/register.dart';
import 'package:xiaozhi_im_client/screens/conversations.dart';
import 'package:xiaozhi_im_client/widgets/avatar.dart';
import 'package:xiaozhi_im_client/widgets/gradient_button.dart';
import 'package:xiaozhi_im_client/widgets/server_settings.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _u = TextEditingController();
  final _p = TextEditingController();
  bool _load = false;
  bool _obscure = true;
  String? _err;
  /// 最近一次登录异常的原始对象，用于决定要不要显示"切换服务器"按钮
  ApiException? _lastErr;

  @override
  void dispose() {
    _u.dispose();
    _p.dispose();
    super.dispose();
  }

  Future<void> _openServer() async {
    final changed = await showServerSettings(context);
    if (changed == true && mounted) setState(() {});
  }

  void _login() async {
    if (_u.text.trim().isEmpty || _p.text.isEmpty) {
      setState(() => _err = '请填写账号和密码');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _load = true;
      _err = null;
      _lastErr = null;
    });
    try {
      await ImApi().login(_u.text.trim(), _p.text);
      if (mounted) {
        Navigator.pushReplacement(context,
            MaterialPageRoute(builder: (_) => const ConversationsScreen()));
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _err = e.toString().replaceFirst('Exception: ', '');
          _lastErr = e is ApiException ? e : null;
        });
      }
    } finally {
      if (mounted) setState(() => _load = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          actions: [
            IconButton(
              tooltip: '服务器设置',
              onPressed: _openServer,
              icon: const Icon(Icons.settings_rounded),
            ),
            const SizedBox(width: 6),
          ],
        ),
        body: Container(
          decoration: const BoxDecoration(gradient: AppTheme.bgGradient),
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 380),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(28, 34, 28, 26),
                  decoration: BoxDecoration(
                    color: AppColors.bgElevated,
                    borderRadius: BorderRadius.circular(AppRadii.xl),
                    border: Border.all(color: AppColors.border),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.35),
                        blurRadius: 40,
                        offset: const Offset(0, 18),
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Center(child: BrandLogo(size: 68)),
                      const SizedBox(height: 20),
                      const Center(
                        child: Text('小智 IM',
                            style: TextStyle(
                                fontSize: 25,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1)),
                      ),
                      const SizedBox(height: 6),
                      const Center(
                        child: Text('登录到你的私有通讯',
                            style: TextStyle(
                                color: AppColors.textSub, fontSize: 13.5)),
                      ),
                      const SizedBox(height: 26),
                      if (_err != null) ...[
                        _errorBox(_err!),
                        if (_lastErr != null && _lastErr!.isNetwork) ...[
                          const SizedBox(height: 10),
                          Center(
                            child: TextButton.icon(
                              onPressed: _openServer,
                              icon: const Icon(Icons.dns_rounded, size: 16),
                              label: const Text('切换服务器 →'),
                              style: TextButton.styleFrom(
                                foregroundColor: AppColors.brand,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 6),
                              ),
                            ),
                          ),
                        ],
                      ],
                      TextField(
                        controller: _u,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          hintText: '账号',
                          prefixIcon: Icon(Icons.person_outline_rounded,
                              size: 20, color: AppColors.textWeak),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _p,
                        obscureText: _obscure,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _login(),
                        decoration: InputDecoration(
                          hintText: '密码',
                          prefixIcon: const Icon(Icons.lock_outline_rounded,
                              size: 20, color: AppColors.textWeak),
                          suffixIcon: IconButton(
                            onPressed: () =>
                                setState(() => _obscure = !_obscure),
                            icon: Icon(
                              _obscure
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                              size: 19,
                              color: AppColors.textWeak,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      GradientButton(
                        text: '登 录',
                        loading: _load,
                        onPressed: _load ? null : _login,
                      ),
                      const SizedBox(height: 14),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Text('还没有账号？',
                              style: TextStyle(
                                  color: AppColors.textWeak, fontSize: 13.5)),
                          TextButton(
                            onPressed: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) => const RegisterScreen())),
                            child: const Text('立即注册'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      GestureDetector(
                        onTap: _openServer,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: AppColors.brand.withValues(alpha: 0.08),
                            borderRadius:
                                BorderRadius.circular(AppRadii.sm),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _modeIcon(Config.mode),
                                size: 12,
                                color: AppColors.brand,
                              ),
                              const SizedBox(width: 5),
                              Flexible(
                                child: Text(
                                  _modeText(),
                                  style: const TextStyle(
                                    color: AppColors.brand,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 4),
                              const Icon(Icons.edit_rounded,
                                  size: 11, color: AppColors.brand),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );

  Widget _errorBox(String msg) => Container(
        margin: const EdgeInsets.only(bottom: 16),
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
                  style: const TextStyle(
                      color: AppColors.danger, fontSize: 13)),
            ),
          ],
        ),
      );

  IconData _modeIcon(String mode) {
    switch (mode) {
      case Config.modeLan:
        return Icons.wifi_rounded;
      case Config.modeWan:
        return Icons.public_rounded;
      default:
        return Icons.auto_mode_rounded;
    }
  }

  String _modeText() {
    final url = Config.baseUrl;
    switch (Config.mode) {
      case Config.modeLan:
        return '内网 · $url';
      case Config.modeWan:
        return '外网 · $url';
      default:
        return '自动 · $url';
    }
  }
}
