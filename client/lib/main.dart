import 'package:flutter/material.dart';
import 'core/storage.dart';
import 'screens/login.dart';
import 'screens/conversations.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: '小智 IM',
        theme: ThemeData.dark().copyWith(
          primaryColor: const Color(0xFF5865F2),
          colorScheme: ColorScheme.dark(
            primary: const Color(0xFF5865F2),
            secondary: const Color(0xFF5865F2),
          ),
        ),
        home: const AuthGate(),
        debugShowCheckedModeBanner: false,
      );
}

class AuthGate extends StatefulWidget {
  const AuthGate({super.key});
  @override
  State<AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<AuthGate> {
  bool? _has;
  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    final t = await Storage.getToken();
    setState(() => _has = t != null && t.isNotEmpty);
  }

  @override
  Widget build(BuildContext context) {
    if (_has == null) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return _has! ? const ConversationsScreen() : const LoginScreen();
  }
}
