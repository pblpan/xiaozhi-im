import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// 蓝牙价签 / 标签打印机的连接层。**只管"连上并写字节"，一个排版指令都不碰。**
///
/// ── 走经典蓝牙 SPP，不走 BLE ─────────────────────────────────────
/// 主流蓝牙价签机、标签机、收银小票机都是**经典蓝牙 SPP（串口 RFCOMM）**，
/// 服务 UUID 固定为 00001101-0000-1000-8000-00805F9B34FB，各家都一样。
/// 字节流直接就是 ESC/POS —— 打印机不认识解析器，只认字节，所以这里也
/// **不认任何型号**：换机器只要在系统蓝牙里重新配对，不用改代码。
///
/// ⚠️ 先前试过 flutter_blue_plus，已弃用：它的 FlutterBluePlus License
///    **明确要求营利组织另买商业许可**（"For for-profit organizations, a
///    commercial license is required"）。超市打价签是营利用途，用了就是违约。
///    改走 Android 原生 `android.bluetooth`（Apache-2.0），没有这个问题。
///
/// ── 平台边界 ────────────────────────────────────────────────────
/// 只做 **Android**。Windows 桌面端没有经典蓝牙串口通路，
/// 进这个页面会看到一段明说"不支持"的话，而不是"点了打印转圈半天然后失败"。
class BtPrinterDevice {
  const BtPrinterDevice({required this.address, required this.name});

  /// 蓝牙 mac 地址（列表里的身份，重连就靠它）。
  final String address;

  /// 蓝牙名。打印机常给个默认名（"TP-xxx"、"BT-PRINTER"），界面上要认得出。
  final String name;

  String get displayName => name.isEmpty ? '未命名的打印机' : name;

  @override
  String toString() => '$displayName($address)';
}

/// 连接/写入失败。原生侧给 code，这里给出"用户接下来干什么"的话。
class BtPrinterError implements Exception {
  const BtPrinterError(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => '$code: $message';
}

/// 已经连上的打印机。
class BtPrinterLink {
  BtPrinterLink(this._address);

  final String _address;

  bool _closed = false;

  bool get isOpen => !_closed;

  /// 把一整批 ESC/POS 字节写给打印机。
  ///
  /// 🔴 分块在原生侧做（`BluetoothPrinter.write`）：蓝牙 socket 的缓冲会被
  ///    一次超大的 write 顶住，现场表现是"卡在写到一半、然后报错"，
  ///    看着像打印机的毛病，其实是内存/缓冲的问题。
  Future<void> write(List<int> bytes) async {
    if (_closed) throw StateError('打印机已经断开（$_address）');
    if (bytes.isEmpty) return;
    // 🔴 转成 Uint8List 再过通道：普通 List<int> 会被逐元素编码，
    //    打 50 张标签时那一串指令能多出好几个数量级的中间字节。
    await BtPrinter._channel.invokeMethod<void>('write', <String, Object?>{
      'address': _address,
      'bytes': Uint8List.fromList(bytes),
    });
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await BtPrinter._channel.invokeMethod<void>('disconnect',
          <String, Object?>{'address': _address});
    } catch (_) {
      // 断开失败没有补救价值，也不该让用户以为"失败"了然后反复点。
    }
  }
}

/// 蓝牙打印机：查权限、列已配对设备、连接、写字节。
class BtPrinter {
  BtPrinter._();

  /// 与 `android/.../BluetoothPrinter.kt` 的通道名必须逐字一致。
  static const MethodChannel _channel =
      MethodChannel('xiaozhi/btprint');

  /// 这个平台能不能真的连打印机。
  ///
  /// 🔴 用**平台判断**而不是 try/catch 包住调用：在这台设备上不可用是常态
  ///    （Windows 桌面端就是这样），不该表现为"try 里抛异常、catch 里悄悄
  ///    退化成别的出口" —— 那种写法会让"点打印没反应"变成最难查的问题。
  static bool get supported => Platform.isAndroid;

  static String get unsupportedReason => Platform.isWindows
      ? 'Windows 桌面端不支持蓝牙打印机。价签机配的是经典蓝牙串口，'
          '而桌面版没有这条通路。换用手机端打印。'
      : '当前设备不支持蓝牙打印。';

  /// 缺蓝牙权限就申请；返回 false 时界面该让用户去设置里给。
  static Future<bool> ensurePermission() async {
    if (!supported) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('ensurePermission');
      return ok ?? false;
    } on PlatformException catch (_) {
      return false;
    }
  }

  /// 列出**已经在系统蓝牙里配对过**的打印机。
  ///
  /// 不做扫描：打印机通常先用"设置→蓝牙"配对好，这一步系统里已经做过；
  /// 再让它扫一遍，用户要在"扫到的几十个蓝牙设备里"里挑一台打印机，纯属添堵。
  /// 例外情况（从没配对过）界面上会说明该怎么做。
  static Future<List<BtPrinterDevice>> listPaired() async {
    if (!supported) return const <BtPrinterDevice>[];
    final raw = await _channel.invokeMethod<List<dynamic>>('listPaired');
    if (raw == null) return const <BtPrinterDevice>[];
    final out = <BtPrinterDevice>[];
    for (final r in raw) {
      final m = r as Map<dynamic, dynamic>;
      final addr = (m['address'] ?? '').toString();
      if (addr.isEmpty) continue; // 没地址的设备重连不了，列出来是干扰
      out.add(BtPrinterDevice(
        address: addr,
        name: (m['name'] ?? '').toString(),
      ));
    }
    return out;
  }

  /// 连接。失败时抛 [BtPrinterError]，带上(code, message) 让界面说人话。
  static Future<BtPrinterLink> connect(BtPrinterDevice device) async {
    if (!supported) {
      throw BtPrinterError('UNSUPPORTED', unsupportedReason);
    }
    try {
      await _channel.invokeMethod<void>('connect', <String, Object?>{
        'address': device.address,
      });
    } on PlatformException catch (e) {
      final code = e.code.isEmpty ? 'CONNECT_FAILED' : e.code;
      final msg = e.message ?? e.code;
      // code 是原生给的，但 message 有可能被跨层丢掉，兜一层别显示空白。
      throw BtPrinterError(code, msg.isEmpty ? code : msg);
    }
    return BtPrinterLink(device.address);
  }

  /// 把原生侧的错误码翻成人话。
  ///
  /// 🔴 每条都要答"用户接下来干什么"。写"连接失败"等于没说 ——
  ///    用户站在打印机前面，需要的是"先开机""先在系统蓝牙里配对""先给权限"。
  static BtPrinterError explain(Object e) {
    if (e is BtPrinterError) return e;
    if (e is PlatformException) {
      switch (e.code) {
        case 'PERMISSION_DENIED':
          return const BtPrinterError(
            'PERMISSION_DENIED',
            '没给蓝牙权限。到「设置→应用→权限」里打开蓝牙，再回来打印。',
          );
        case 'BLUETOOTH_OFF':
          return const BtPrinterError(
            'BLUETOOTH_OFF',
            '手机蓝牙没开。下拉栏打开蓝牙再试。',
          );
        case 'NO_PEER':
          return const BtPrinterError(
            'NO_PEER',
            '没找到这台打印机。到「设置→蓝牙」里先和它配对一次，再回来打印。',
          );
        case 'NOT_OPEN':
          return const BtPrinterError(
            'NOT_OPEN',
            '打印机已经断了。重新连一次。',
          );
      }
    }
    if (e is MissingPluginException) {
      return const BtPrinterError(
        'NO_IMPL',
        '这台设备没编译蓝牙打印（Android 才有）。',
      );
    }
    final s = e.toString();
    if (s.contains('Bluetooth is off')) {
      return const BtPrinterError(
        'BLUETOOTH_OFF',
        '手机蓝牙没开。下拉栏打开蓝牙再试。',
      );
    }
    return BtPrinterError('$e', '打印失败：$e');
  }
}
