import 'package:flutter_test/flutter_test.dart';
import 'package:xiaozhi_im_client/core/emoji.dart';
import 'package:xiaozhi_im_client/core/file_io.dart';

void main() {
  group('表情数据', () {
    test('分组非空且每个表情非空', () {
      expect(EmojiData.groups, isNotEmpty);
      for (final g in EmojiData.groups) {
        expect(g.label, isNotEmpty);
        expect(g.emojis, isNotEmpty, reason: '分组「${g.label}」不能是空的');
        for (final e in g.emojis) {
          expect(e.trim(), isNotEmpty);
          expect(e.contains(' '), isFalse, reason: '表情「$e」不该含空格');
        }
      }
    });

    test('跨分组没有重复（同一表情出现在两个分类里会让人困惑）', () {
      final seen = <String, String>{};
      for (final g in EmojiData.groups) {
        for (final e in g.emojis) {
          expect(seen.containsKey(e), isFalse,
              reason: '「$e」同时出现在「${seen[e]}」和「${g.label}」');
          seen[e] = g.label;
        }
      }
    });

    test('每组数量够铺满面板', () {
      for (final g in EmojiData.groups) {
        expect(g.emojis.length, greaterThanOrEqualTo(EmojiData.perRow),
            reason: '分组「${g.label}」至少要有 ${EmojiData.perRow} 个');
      }
    });
  });

  group('纯表情判定', () {
    test('1~3 个表情算纯表情', () {
      expect(EmojiData.isEmojiOnly('😄'), isTrue);
      expect(EmojiData.isEmojiOnly('😄😄'), isTrue);
      expect(EmojiData.isEmojiOnly('😄😄😄'), isTrue);
      expect(EmojiData.isEmojiOnly('❤️'), isTrue);
      expect(EmojiData.isEmojiOnly(' 👍 '), isTrue, reason: '首尾空白应被忽略');
    });

    test('超过 3 个不算（避免长串表情被撑得很大）', () {
      expect(EmojiData.isEmojiOnly('😄😄😄😄'), isFalse);
    });

    test('夹了文字就不算', () {
      expect(EmojiData.isEmojiOnly('你好'), isFalse);
      expect(EmojiData.isEmojiOnly('😄你好'), isFalse);
      expect(EmojiData.isEmojiOnly('好的😄'), isFalse);
      expect(EmojiData.isEmojiOnly(''), isFalse);
      expect(EmojiData.isEmojiOnly('   '), isFalse);
    });

    test('非面板内的普通 emoji 也能识别（走码位兜底）', () {
      expect(EmojiData.isEmojiOnly('🦩'), isTrue);
    });
  });

  group('文件名清洗', () {
    test('去掉各平台非法字符', () {
      expect(FileIo.safeName('a/b\\c:d*e?f"g<h>i|j'), 'a_b_c_d_e_f_g_h_i_j');
      expect(FileIo.safeName('  报表.xlsx  '), '报表.xlsx');
      expect(FileIo.safeName(''), 'file');
    });

    test('超长名字截断但保留扩展名', () {
      final long = '${'a' * 300}.xlsx';
      final out = FileIo.safeName(long);
      expect(out.length, lessThanOrEqualTo(120));
      expect(out.endsWith('.xlsx'), isTrue);
    });
  });
}
