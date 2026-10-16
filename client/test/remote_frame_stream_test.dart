// 自研画面通道：帧分片 / 重组协议 + 画质档位表
//
// 【为什么重点测"烂数据不炸"和"乱序丢片"】
// 这里处理的是**网络上流过来的任意字节**：对面可能跑的是旧版本、可能被截断、
// 也可能就是丢片了（画面通道是 unordered + 最多重传 1 次的，丢片是常态）。
// 这一段写蹦了的表象是控制端 App 直接崩溃；写对了但策略不对的表象是
// "画面停在某一帧不动"或者"画面来回跳" —— 后者只能靠这些用例守住。
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/remote_assist.dart';
import 'package:xiaozhi_im_client/core/remote_frame_stream.dart';

Uint8List _bytes(int n, [int seed = 0]) =>
    Uint8List.fromList(List<int>.generate(n, (i) => (i + seed) & 0xFF));

/// 把一帧切成片
List<Uint8List> _pack(int seq, int len, {int w = 960, int h = 540}) =>
    packRemoteFrame(seq: seq, width: w, height: h, jpeg: _bytes(len, seq));

void main() {
  group('packRemoteFrame', () {
    test('小于一片的帧只产生一条报文', () {
      final parts = _pack(1, 1000);
      expect(parts.length, 1);
      expect(parts.first.lengthInBytes, kRemoteFrameHeader + 1000);
    });

    test('刚好一片的边界不分出多余的空片', () {
      expect(_pack(1, kRemoteFrameChunk).length, 1);
      expect(_pack(1, kRemoteFrameChunk + 1).length, 2);
    });

    test('头里带版本、序号、分片数与尺寸', () {
      final parts = _pack(0x01020304, kRemoteFrameChunk * 2, w: 1280, h: 720);
      expect(parts.length, 2);
      final bd = ByteData.sublistView(parts.first);
      expect(parts.first[0], kRemoteFrameVer);
      expect(bd.getUint32(2), 0x01020304);
      expect(bd.getUint16(6), 0); // idx
      expect(bd.getUint16(8), 2); // total
      expect(bd.getUint16(10), 1280);
      expect(bd.getUint16(12), 720);
      expect(ByteData.sublistView(parts[1]).getUint16(6), 1);
    });
  });

  group('RemoteFrameAssembler', () {
    test('按序到达 → 逐字节还原', () {
      final src = _bytes(70000, 7);
      final parts = packRemoteFrame(
          seq: 1, width: 1280, height: 720, jpeg: src);
      final asm = RemoteFrameAssembler();
      RemoteFrame? done;
      for (final p in parts) {
        done = asm.feed(p) ?? done;
      }
      expect(done, isNotNull);
      expect(done!.width, 1280);
      expect(done.height, 720);
      expect(done.jpeg.lengthInBytes, src.lengthInBytes);
      expect(done.jpeg, equals(src));
      expect(asm.completed, 1);
      expect(asm.dropped, 0);
    });

    test('乱序到达也能拼齐（通道是 unordered 的）', () {
      final src = _bytes(50000, 3);
      final parts = packRemoteFrame(
          seq: 9, width: 960, height: 540, jpeg: src);
      final asm = RemoteFrameAssembler();
      RemoteFrame? done;
      for (final p in parts.reversed) {
        done = asm.feed(p) ?? done;
      }
      expect(done, isNotNull);
      expect(done!.jpeg, equals(src));
    });

    test('缺一片 → 这一帧不出，且不算完成', () {
      final parts = _pack(1, kRemoteFrameChunk * 2);
      final asm = RemoteFrameAssembler();
      expect(asm.feed(parts[0]), isNull);
      expect(asm.completed, 0);
    });

    test('缺片的旧帧被新序号顶掉 → 计入 dropped，新帧照常出', () {
      final old = _pack(1, kRemoteFrameChunk * 2);
      final fresh = _pack(2, kRemoteFrameChunk * 2);
      final asm = RemoteFrameAssembler();
      expect(asm.feed(old[0]), isNull); // 只来了第 0 片
      RemoteFrame? done;
      for (final p in fresh) {
        done = asm.feed(p) ?? done;
      }
      expect(done, isNotNull);
      expect(asm.dropped, 1);
      expect(asm.completed, 1);
    });

    test('迟到的旧序号残片不会污染当前帧', () {
      final old = _pack(1, kRemoteFrameChunk * 2);
      final fresh = _pack(2, kRemoteFrameChunk * 2);
      final asm = RemoteFrameAssembler();
      asm.feed(fresh[0]);
      // 旧帧的残片姗姗来迟
      expect(asm.feed(old[1]), isNull);
      // 新帧仍然能拼齐
      expect(asm.feed(fresh[1]), isNotNull);
      expect(asm.completed, 1);
    });

    test('同一帧的重复片被忽略，不影响结果', () {
      final src = _bytes(40000, 5);
      final parts =
          packRemoteFrame(seq: 4, width: 960, height: 540, jpeg: src);
      final asm = RemoteFrameAssembler();
      RemoteFrame? done;
      for (final p in parts) {
        final first = asm.feed(p);
        expect(asm.feed(p), isNull, reason: '重复片必须被忽略');
        if (first != null) done = first;
      }
      expect(done, isNotNull);
      expect(done!.jpeg, equals(src));
    });

    test('帧交出去之后再来的同序号片不再重复上屏', () {
      final parts = _pack(6, 100);
      final asm = RemoteFrameAssembler();
      expect(asm.feed(parts[0]), isNotNull);
      expect(asm.feed(parts[0]), isNull);
      expect(asm.completed, 1);
    });

    test('序号回绕（u32 溢出）仍然判定为新帧', () {
      final a = _pack(0xFFFFFFFF, 100);
      final b = _pack(0, 100);
      final asm = RemoteFrameAssembler();
      expect(asm.feed(a[0]), isNotNull);
      expect(asm.feed(b[0]), isNotNull);
      expect(asm.completed, 2);
    });

    test('畸形报文一律丢弃且不抛异常', () {
      final asm = RemoteFrameAssembler();
      final good = _pack(1, kRemoteFrameChunk * 2);
      final malformed = <Uint8List>[
        Uint8List(0), // 空
        Uint8List(kRemoteFrameHeader - 1), // 比头还短
        Uint8List(kRemoteFrameHeader), // 头全 0（ver=0 且 total=0）
        _mutate(good[0], (bd) => bd.setUint8(0, 99)), // 版本不对
        _mutate(good[0], (bd) => bd.setUint16(8, 0)), // total=0
        _mutate(good[0], (bd) => bd.setUint16(8, 0xFFFF)), // total 越界
        _mutate(good[0], (bd) => bd.setUint16(6, 5)), // idx >= total
        _mutate(good[0], (bd) => bd.setUint16(10, 0)), // 宽度 0
        _mutate(good[0], (bd) => bd.setUint16(12, 0)), // 高度 0
      ];
      for (final m in malformed) {
        expect(() => asm.feed(m), returnsNormally, reason: '畸形报文不该抛');
        expect(asm.feed(m), isNull);
      }
      // 挨完一堆烂数据，正常帧仍然要能过
      RemoteFrame? done;
      for (final p in good) {
        done = asm.feed(p) ?? done;
      }
      expect(done, isNotNull);
    });

    test('reset 之后重新开始（会话重连复用同一个实例）', () {
      final asm = RemoteFrameAssembler();
      asm.feed(_pack(1, 100)[0]);
      asm.reset();
      expect(asm.completed, 0);
      expect(asm.dropped, 0);
      expect(asm.width, isNull);
      // 会话重连后序号从头开始，也必须当成新帧
      expect(asm.feed(_pack(1, 100)[0]), isNotNull);
    });
  });

  group('画质档位表', () {
    test('5 档，宽度单调递减（"越大越糊"的承诺不能反）', () {
      expect(kRemoteFrameLevels.length, 5);
      for (var i = 1; i < kRemoteFrameLevels.length; i++) {
        expect(
          kRemoteFrameLevels[i].width < kRemoteFrameLevels[i - 1].width,
          isTrue,
          reason: '第 $i 档应比上一档更省',
        );
      }
      for (final l in kRemoteFrameLevels) {
        expect(l.width, greaterThan(0));
        expect(l.quality, inInclusiveRange(1, 100));
        // JPEG 编码器对奇数宽高会内部补齐，白白多花时间
        expect(l.width.isEven, isTrue);
      }
    });

    test('默认档位落在表内', () {
      expect(kRemoteFrameDefaultLevel, inInclusiveRange(0, kRemoteFrameLevels.length - 1));
    });

    test('分片负载小于常见的 DataChannel 单条消息上限', () {
      expect(kRemoteFrameChunk, lessThan(64 * 1024));
    });
  });
}

/// 复制一份再改某几个字节，用来造畸形报文。
Uint8List _mutate(Uint8List src, void Function(ByteData) f) {
  final copy = Uint8List.fromList(src);
  f(ByteData.sublistView(copy));
  return copy;
}
