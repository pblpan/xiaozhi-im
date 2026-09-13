import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/discover.dart';

/// LanDiscover 单测：本机起一个"假服务器"（UDP 应答器），
/// 验证 scan() 能发探测、收应答、解析字段、按 URL 去重。
void main() {
  test('scan 能发现应答探测的假服务器并解析字段', () async {
    final responder = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4, 0, reuseAddress: true);
    final probePort = responder.port; // scan 往这个端口广播，应答器就在这听
    final received = <Datagram>[];

    final sub = responder.listen((ev) {
      if (ev != RawSocketEvent.read) return;
      final dg = responder.receive();
      if (dg == null) return;
      received.add(dg);
      if (utf8.decode(dg.data).trim() != LanDiscover.probe) return;
      // 模拟小智服务器：应答探测来源
      final reply = utf8.encode(jsonEncode({
        'app': 'xiaozhi-im',
        'httpPort': 3602,
        'companyName': '盛京',
        'friendMode': 'work',
        'serverVersion': '9.9.9-test',
      }));
      responder.send(reply, dg.address, dg.port);
    });

    final found = await LanDiscover.scan(
      timeout: const Duration(seconds: 3),
      port: probePort,
    );

    expect(received, isNotEmpty, reason: 'scan 应该发出过探测包');
    expect(found, isNotEmpty, reason: '假服务器应答了，scan 应该发现它');
    final s = found.first;
    expect(s.serverVersion, '9.9.9-test');
    expect(s.companyName, '盛京');
    expect(s.friendMode, 'work');
    expect(s.url, 'http://${s.ip}:3602');

    sub.cancel();
    responder.close();
  });

  test('scan 对无应答的环境返回空列表而不抛错', () async {
    // 绑一个"只听不答"的端口，模拟没有小智服务器的网络
    final silent = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4, 0, reuseAddress: true);
    final found = await LanDiscover.scan(
      timeout: const Duration(milliseconds: 800),
      port: silent.port,
    );
    expect(found, isEmpty);
    silent.close();
  });
}
