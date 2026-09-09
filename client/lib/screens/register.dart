import 'package:flutter/material.dart';
import 'package:xiaozhi_im_client/api.dart';
import 'package:xiaozhi_im_client/screens/conversations.dart';

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
  String? _err;

  void _register() async {
    setState(() => _load = true);
    try {
      await ImApi().register(_u.text.trim(), _p.text, _n.text.trim());
      if (mounted) {
        Navigator.pushReplacement(context,
            MaterialPageRoute(builder: (_) => const ConversationsScreen()));
      }
    } catch (e) {
      if (mounted) setState(() => _err = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _load = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('注册账号')),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 340),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_err != null)
                      Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(8),
                        color: Colors.red.withValues(alpha: 0.15),
                        child: Text(_err!, style: const TextStyle(color: Colors.redAccent)),
                      ),
                    TextField(
                      controller: _u,
                      decoration: const InputDecoration(labelText: '账号(至少3位)', border: OutlineInputBorder()),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _n,
                      decoration: const InputDecoration(labelText: '昵称', border: OutlineInputBorder()),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _p,
                      obscureText: true,
                      decoration: const InputDecoration(labelText: '密码', border: OutlineInputBorder()),
                    ),
                    const SizedBox(height: 18),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _load ? null : _register,
                        child: _load ? const CircularProgressIndicator(strokeWidth: 2) : const Text('注册并登录'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
}
