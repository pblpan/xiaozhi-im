import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 包完整性自校验 —— 客户端加固的第二条（2026-09-16，任务 #127）。
///
/// 【防的是什么】
///   别人拿到安装包 → 反编译 / 改代码（去掉授权校验、改成连自己的服务器、
///   塞个后门）→ **用他自己的签名重新打包** → 装到手机上。
///   R8 混淆只让"读代码"变贵，挡不住"改完重签"这件事；能挡住它的是签名校验：
///   重签之后的包签名指纹必然变，启动时对不上就拒绝进入。
///
/// 【两条腿，强度不一样，别混为一谈】
///   · Android：读**运行时真实签名证书**的 SHA-256，与内置期望值比对。
///     这是硬判据 —— 除了我们自己，没人能产出签名一致的包。
///   · Windows：比对 exe 与 data/app.so 的 SHA-256 与安装时写下的
///     integrity.dat。这是**篡改检测（减速带）**：能拦住"换掉 exe / 改 app.so"
///     这类做法，但攻击者把校验点一起改掉就绕过了 —— Windows 上没有
///     代码签名证书就不存在等价于 Android 的硬判据。如实标注，不吹。
///
/// 【失败策略：确定性不一致才拦，自己出错就放行】
///   校验本身抛异常（读不到文件 / 通道不可用）时**不拦人** —— 宁可少拦，
///   也不能因为一个辅助机制把正常用户锁在门外（同 licenseGate 的放行思路）。
///   只有拿到"明确不一致"的结论才判 [blocked]。
class Integrity {
  Integrity._();

  /// 非 null = 判定为被篡改，App 拒绝进入；值是给用户看的原因。
  static String? blocked;

  /// 判定为篡改时的技术细节（写日志/排障用，界面折叠展示）
  static String? detail;

  /// Android 期望的签名证书 SHA-256 由**原生侧**持有（AppIntegrity.kt 的
  /// EXPECTED_CERT_SHA256），这里不重复写一份 —— 两处各写一份的话，
  /// 哪天换了签名密钥只改一边，就会出现"自己出的包被自己拦下"。
  /// Dart 只负责读结论。
  static const MethodChannel _ch = MethodChannel('xiaozhi/guard');

  /// 启动时调用（runApp 之前，且在 WidgetsFlutterBinding.ensureInitialized() 之后）。
  /// 任何情况下都不抛异常。
  static Future<void> check() async {
    try {
      if (kIsWeb) return;
      if (Platform.isAndroid) {
        await _checkAndroid();
      } else if (Platform.isWindows) {
        await _checkWindows();
      }
    } catch (e) {
      // 辅助机制不许把用户挡在门外：出错就放行
      debugPrint('[integrity] 校验过程出错，放行：$e');
    }
  }

  // ------------------------------------------------------------------
  // Android：签名证书指纹
  // ------------------------------------------------------------------
  static Future<void> _checkAndroid() async {
    final Map<dynamic, dynamic> r;
    try {
      r = await _ch.invokeMethod<Map<dynamic, dynamic>>('checkIntegrity') ??
          const {};
    } on MissingPluginException {
      // 通道不存在 = 原生侧没编译进去（老包/其他平台），不拦
      debugPrint('[integrity] 原生通道缺失，跳过签名校验');
      return;
    }
    final verdict = (r['verdict'] ?? '').toString();
    final actual = (r['certSha256'] ?? '').toString().toLowerCase();
    final expected = (r['expected'] ?? '').toString().toLowerCase();
    final why = (r['detail'] ?? '').toString();

    if (verdict == 'ok') {
      debugPrint('[integrity] 签名校验通过');
      return;
    }
    if (verdict != 'tampered') {
      // unknown：拿不到签名信息等 → 放行但留痕
      debugPrint('[integrity] 签名状态未知（$why），放行');
      return;
    }
    blocked = '此安装包不是官方版本，已停止运行';
    detail = '签名证书指纹不一致\n'
        '期望：${expected.isEmpty ? '(未提供)' : expected}\n'
        '实际：${actual.isEmpty ? '(读取失败)' : actual}'
        '${why.isEmpty ? '' : '\n$why'}';
  }

  // ------------------------------------------------------------------
  // Windows：exe + data/app.so 的哈希对账
  // ------------------------------------------------------------------
  /// 安装包在同目录留的哈希清单；没有这个文件说明是开发态（build 目录直跑）
  /// 或绿色复制版，此时**跳过校验**（不能因为没清单就不让人用）。
  static const String stampName = 'integrity.dat';

  static Future<void> _checkWindows() async {
    final exe = File(Platform.resolvedExecutable);
    final dir = exe.parent;
    final stamp = File('${dir.path}${Platform.pathSeparator}$stampName');
    if (!await stamp.exists()) {
      debugPrint('[integrity] 无 $stampName，跳过（开发态/绿色版）');
      return;
    }

    Map<String, dynamic> json;
    try {
      json = jsonDecode(await stamp.readAsString()) as Map<String, dynamic>;
    } catch (e) {
      debugPrint('[integrity] $stampName 解析失败，放行：$e');
      return;
    }
    final files = json['files'];
    if (files is! Map) {
      debugPrint('[integrity] $stampName 结构不对，放行');
      return;
    }

    final sep = Platform.pathSeparator;
    final bad = <String>[];
    for (final entry in files.entries) {
      final rel = entry.key.toString();
      final want = entry.value.toString().toLowerCase();
      final f = File(dir.path + sep + rel.replaceAll('/', sep));
      if (!await f.exists()) {
        bad.add('$rel（文件缺失）');
        continue;
      }
      final got = (await sha256.bind(f.openRead()).first).toString();
      if (got != want) bad.add(rel);
    }

    if (bad.isEmpty) {
      debugPrint('[integrity] 程序文件校验通过');
      return;
    }
    blocked = '程序文件已被修改，已停止运行';
    detail = '以下文件与安装时的记录不一致：\n· ${bad.join('\n· ')}\n\n'
        '如果你没有手动改动过安装目录，请从官方安装包重新安装。';
  }

  /// 供 build 脚本/自测复用：算一个文件的 sha256 十六进制串
  static Future<String> sha256OfFile(String path) async {
    final f = File(path);
    return (await sha256.bind(f.openRead()).first).toString();
  }
}
