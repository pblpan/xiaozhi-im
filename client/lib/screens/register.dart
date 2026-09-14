import 'package:flutter/material.dart';
import 'package:xiaozhi_im_client/api.dart';
import 'package:xiaozhi_im_client/core/remote_config.dart';
import 'package:xiaozhi_im_client/core/theme.dart';
import 'package:xiaozhi_im_client/screens/home_shell.dart';
import 'package:xiaozhi_im_client/widgets/avatar.dart';
import 'package:xiaozhi_im_client/widgets/gradient_button.dart';

class RegisterScreen extends StatefulWidget {
  const RegisterScreen({super.key});
  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
  final _u = TextEditingController();
  final _p = TextEditingController();
  final _n = TextEditingController();
  bool _load = false;
  bool _obscure = true;
  String? _err;

  /// 工作模式下不允许自助注册（服务端会 403），提前提示别让人白填一遍
  bool _workMode = false;

  @override
  void initState() {
    super.initState();
    _probeMode();
  }

  Future<void> _probeMode() async {
    final b = await RemoteConfig.fetchPublic();
    final work = b['friendMode'].toString() == 'work';
    if (mounted && work != _workMode) setState(() => _workMode = work);
  }

  @override
  void dispose() {
    _u.dispose();
    _p.dispose();
    _n.dispose();
    super.dispose();
  }

  void _register() async {
    if (_u.text.trim().length < 3) {
      setState(() => _err = '账号至少 3 位');
      return;
    }
    if (_p.text.length < 4) {
      setState(() => _err = '密码至少 4 位');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() {
      _load = true;
      _err = null;
    });
    try {
      await ImApi().register(_u.text.trim(), _p.text, _n.text.trim());
      // 注册成功同样进导航外壳（HomeShell），与登录一致
      if (mounted) {
        Navigator.pushReplacement(
            context, MaterialPageRoute(builder: (_) => const HomeShell()));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _err = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _load = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          backgroundColor: Colors.transparent,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20),
            onPressed: () => Navigator.pop(context),
          ),
        ),
        body: Container(
          decoration: const BoxDecoration(gradient: AppTheme.bgGradient),
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 380),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(28, 30, 28, 28),
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
                      const Center(child: BrandLogo(size: 56)),
                      const SizedBox(height: 16),
                      const Center(
                        child: Text('创建账号',
                            style: TextStyle(
                                fontSize: 21, fontWeight: FontWeight.w700)),
                      ),
                      const SizedBox(height: 4),
                      const Center(
                        child: Text('注册后自动登录',
                            style: TextStyle(
                                color: AppColors.textSub, fontSize: 13)),
                      ),
                      const SizedBox(height: 24),
                      if (_workMode) ...[
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.orange.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                                color: Colors.orange.withValues(alpha: 0.45)),
                          ),
                          child: const Text(
                            '本服务器已开启工作模式：不开放自助注册。\n'
                            '员工账号由管理员在组织机构中按工号录入（初始密码=工号），录入后即可登录。',
                            style: TextStyle(
                                fontSize: 12.5,
                                color: Colors.orange,
                                height: 1.55),
                          ),
                        ),
                        const SizedBox(height: 18),
                      ],
                      if (_err != null) _errorBox(_err!),
                      TextField(
                        controller: _u,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          hintText: '账号（至少 3 位）',
                          prefixIcon: Icon(Icons.person_outline_rounded,
                              size: 20, color: AppColors.textWeak),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _n,
                        textInputAction: TextInputAction.next,
                        decoration: const InputDecoration(
                          hintText: '昵称（选填）',
                          prefixIcon: Icon(Icons.badge_outlined,
                              size: 20, color: AppColors.textWeak),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _p,
                        obscureText: _obscure,
                        textInputAction: TextInputAction.done,
                        onSubmitted: (_) => _register(),
                        decoration: InputDecoration(
                          hintText: '密码（至少 4 位）',
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
                        text: '注册并登录',
                        loading: _load,
                        onPressed: _load ? null : _register,
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
                  style:
                      const TextStyle(color: AppColors.danger, fontSize: 13)),
            ),
          ],
        ),
      );
}
