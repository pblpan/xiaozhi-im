import 'dart:convert';
import 'dart:io';

/// Windows PowerShell 执行器（截图 / OCR 都靠它）。
///
/// 【为什么用 PowerShell 而不是 Win32 FFI】
/// 截图（System.Drawing.CopyFromScreen）和 OCR（Windows.Media.Ocr）走系统自带
/// 能力，用 Dart FFI 手搓 GDI BitBlt / WinRT 互操作的代码量是这里的几倍，
/// 还容易在高 DPI / 多屏上踩坑。PowerShell 是 Windows 自带的，零部署成本。
///
/// 【为什么用 -EncodedCommand 而不是写 .ps1 文件】
/// 带中文路径的 .ps1 会被编码问题坑（PS 5.1 默认按 ANSI 读脚本文件）。
/// EncodedCommand 是 UTF-16LE base64，路径里有中文也不会乱码，还不用落临时文件。
///
/// 🔴 必须调 **Windows PowerShell 5.1**（System32 里那个），不能是 pwsh 7：
///    System.Runtime.WindowsRuntime 这个 WinRT 异步桥只在 5.1 里有。
Future<String?> runPowerShell(String script, {Duration timeout = const Duration(seconds: 25)}) async {
  if (!Platform.isWindows) return null;
  final exe = 'C:\\Windows\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
  if (!File(exe).existsSync()) return null;
  final encoded = base64Encode(utf16LeBytes(script));
  try {
    final r = await Process.run(
      exe,
      ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', encoded],
      stdoutEncoding: utf8,
      stderrEncoding: utf8,
    ).timeout(timeout);
    if (r.exitCode != 0) return null;
    return (r.stdout as String).trim();
  } catch (_) {
    return null; // 超时 / 被安全软件拦截 —— 调用方按"功能不可用"处理
  }
}

/// UTF-16LE 字节（EncodedCommand 的要求）
List<int> utf16LeBytes(String s) {
  final out = <int>[];
  for (final cu in s.codeUnits) {
    out.add(cu & 0xFF);
    out.add((cu >> 8) & 0xFF);
  }
  return out;
}

/// 跑一段"返回结构化结果"的 PS 脚本：约定脚本把 JSON 写到 stdout。
/// 解析失败返回 null（脚本崩了 / 输出混入了别的东西）。
Future<Map<String, dynamic>?> runPowerShellJson(String script,
    {Duration timeout = const Duration(seconds: 25)}) async {
  final s = await runPowerShell(script, timeout: timeout);
  if (s == null) return null;
  return _lastJsonLine(s);
}

Map<String, dynamic>? _lastJsonLine(String s) {
  for (final line in s.split('\n').reversed) {
    final t = line.trim();
    if (t.startsWith('{')) {
      try {
        return (const JsonDecoder().convert(t)) as Map<String, dynamic>;
      } catch (_) { /* 下一行 */ }
    }
  }
  return null;
}
