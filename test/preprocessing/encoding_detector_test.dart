import 'dart:typed_data';

import 'package:docdiff/features/preprocessing/application/encoding_detector.dart';
import 'package:docdiff/features/preprocessing/domain/encoding_type.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EncodingDetector.detect', () {
    test('UTF-8 BOM', () {
      final bytes =
          Uint8List.fromList([0xEF, 0xBB, 0xBF, 0x68, 0x69]); // BOM + 'hi'
      expect(EncodingDetector.detect(bytes), EncodingType.utf8bom);
    });

    test('plain ASCII → ascii', () {
      final bytes = Uint8List.fromList([0x68, 0x69]); // 'hi'
      expect(EncodingDetector.detect(bytes), EncodingType.ascii);
    });

    test('UTF-8 multibyte (Chinese)', () {
      // '中' = U+4E2D → UTF-8: E4 B8 AD
      final bytes = Uint8List.fromList([0xE4, 0xB8, 0xAD]);
      expect(EncodingDetector.detect(bytes), EncodingType.utf8);
    });

    test('GBK byte pair (0xD6 0xD0 = 中 in GBK)', () {
      final bytes = Uint8List.fromList([0xD6, 0xD0]);
      expect(EncodingDetector.detect(bytes), EncodingType.gbk);
    });

    test('empty bytes → ascii', () {
      expect(EncodingDetector.detect(Uint8List(0)), EncodingType.ascii);
    });

    test('random high bytes without structure → unknown', () {
      // A single 0x80 byte is not a valid UTF-8 start, nor a valid GBK lead
      // (lead range is 0x81..0xFE). Should fall through to unknown.
      final bytes = Uint8List.fromList([0x80]);
      expect(EncodingDetector.detect(bytes), EncodingType.unknown);
    });
  });

  group('EncodingDetector.detect · ANSI GBK 误判回归', () {
    test('mixed ASCII high-density GBK Chinese → gbk', () {
      // '你好世界' GBK: C4E3 BAC3 CAC0 BDE7, interleaved with ASCII/spaces.
      // Pairs=4, ASCII<0x80 ignored; UTF-8-miss rate on those 4 frames is
      // 100% (they are invalid UTF-8) → should stay gbk.
      final bytes = Uint8List.fromList([
        0xC4, 0xE3, 0x20, 0xBA, 0xC3, 0x20, 0xCA, 0xC0, 0x20, 0xBD, 0xE7,
        0x41, 0x42, 0x43, // trailing ASCII must not dilute the gate
      ]);
      expect(EncodingDetector.detect(bytes), EncodingType.gbk);
    });

    test('high bytes that pair but are actually valid UTF-8 → utf8 not gbk', () {
      // '中中中' UTF-8 = E4B8AD x3. These bytes also happen to pass the GBK
      // lead+trail shape, but strict UTF-8 is checked FIRST, so must be utf8.
      final bytes = Uint8List.fromList([
        0xE4, 0xB8, 0xAD, 0xE4, 0xB8, 0xAD, 0xE4, 0xB8, 0xAD,
      ]);
      expect(EncodingDetector.detect(bytes), EncodingType.utf8);
    });

    test('sparse unmatched high bytes → not GBK (low pair rate)', () {
      // Bytes with 0x80 lead and trails of 0x21 (below GBK trail floor 0x40)
      // do not form valid GBK pairs → must NOT be gbk.
      final bytes = Uint8List.fromList([
        0x81, 0x21, 0x82, 0x21, 0x83, 0x21, // every trail < 0x40 → loneHigh
      ]);
      expect(EncodingDetector.detect(bytes), isNot(EncodingType.gbk));
    });

    test('normal English text → ascii, never gbk', () {
      final bytes = Uint8List.fromList(
          'The quick brown fox jumps over the lazy dog.'
              .codeUnits
              .map((c) => c & 0xFF)
              .toList());
      final enc = EncodingDetector.detect(bytes);
      expect(enc, anyOf(EncodingType.ascii, EncodingType.utf8));
    });
  });

  group('EncodingDetector.decode · unknown 兜底走 UTF-8 容错', () {
    test('unknown keeps ASCII bytes readable (no Chinese garble)', () {
      // 'café' as ANSI: 63 61 66 E9. unknown 兜底必须保留 ASCII 部分，
      // 且绝不把 E9 强解成 GBK 产生的汉字（而是 UTF-8 替换符或原码点）。
      final bytes = Uint8List.fromList([0x63, 0x61, 0x66, 0xE9]);
      final decoded =
          EncodingDetector.decode(bytes, EncodingType.unknown);
      expect(decoded, startsWith('caf'),
          reason: 'unknown 兜底不应破坏可读 ASCII 前缀');
    });

    test('unknown on GBK-looking bytes does not throw and is non-empty', () {
      final bytes = Uint8List.fromList([0xD6, 0xD0, 0xC4, 0xE3]); // 中你(GBK)
      final decoded =
          EncodingDetector.decode(bytes, EncodingType.unknown);
      expect(decoded, isNotEmpty);
    });

    test('utf8 decode path still lenient when allowMalformed', () {
      // Sanity: binary (unpaired 0xFF) must not throw under unknown path.
      final bytes = Uint8List.fromList([0xFF, 0x65]);
      expect(
        () => EncodingDetector.decode(bytes, EncodingType.unknown),
        returnsNormally,
      );
    });
  });

  group('EncodingDetector.decode', () {
    test('decodes UTF-8', () {
      final bytes = Uint8List.fromList([0x68, 0x69]); // 'hi'
      expect(EncodingDetector.decode(bytes, EncodingType.utf8), 'hi');
    });

    test('decodes UTF-8 BOM, strips BOM', () {
      final bytes =
          Uint8List.fromList([0xEF, 0xBB, 0xBF, 0x68, 0x69]); // BOM + 'hi'
      expect(EncodingDetector.decode(bytes, EncodingType.utf8bom), 'hi');
    });

    test('detect GBK mixed with ASCII sentences', () {
      // GBK '你好' = C4 E3 BA C3, interleaved with ASCII ':' and space.
      final bytes = Uint8List.fromList(
          [0x41, 0x3A, 0xC4, 0xE3, 0x20, 0xBA, 0xC3]);
      // 3 high pairs vs 1 high pair ratio: pairs=2, loneHigh=0 → gbk
      expect(EncodingDetector.detect(bytes), EncodingType.gbk);
    });

    test('unknown encoding decode is lenient (never throws)', () {
      // '中' in GBK = D6 D0. When encoding is unknown we decode via UTF-8
      // with replacement; it must not throw and must return non-empty.
      final bytes = Uint8List.fromList([0xD6, 0xD0, 0xC4, 0xE3]); // 中你
      final decoded =
          EncodingDetector.decode(bytes, EncodingType.unknown);
      expect(decoded, isNotEmpty);
    });

    test('sparse ANSI west-european high bytes → not GBK (miss rate low)',
        () {
      // Single-byte ANSI/Latin-1 accents (@0xE9 etc) do not form GBK pairs,
      // so detect must NOT return gbk (which would garble them as Chinese).
      final bytes = Uint8List.fromList(
          [0x63, 0x61, 0x66, 0xE9]); // "caf" + é (0xE9) as ANSI
      expect(EncodingDetector.detect(bytes), isNot(EncodingType.gbk));
    });

    test('chunked GBK decode equals one-shot decode across chunk boundary', () {
      // '中' (GBK) = D6 D0. 130k bytes → 65k chars, crossing many 64KB chunk
      // edges so alignment logic is exercised. Chunked must equal one-shot.
      final n = 130000;
      final gbkBytes = Uint8List.fromList(
        List.generate(n, (i) => i.isEven ? 0xD6 : 0xD0));
      final oneShot =
          EncodingDetector.decode(gbkBytes, EncodingType.gbk);
      final chunked =
          EncodingDetector.decodeChunked(gbkBytes, EncodingType.gbk);
      expect(chunked, oneShot,
          reason: '分块解码应与一次性解码结果一致');
      expect(oneShot, isNotEmpty);
      expect(oneShot.codeUnits.every((c) => c != 0xFFFD), isTrue,
          reason: '分块不应产生替换符（跨块半个字符）');
    });

    test('real GBK bytes decode to Chinese, not latin-1 mojibake', () {
      // 『《奇怪的先生们》』GBK 字节取自真实用户文件头部：
      // A1B6 C6E6 B9D6 B5C4 CFC8 C9FA C3C7 A1B7 = 《奇怪的先生们》
      final bytes = Uint8List.fromList([
        0xA1, 0xB6, 0xC6, 0xE6, 0xB9, 0xD6, 0xB5, 0xC4, //
        0xCF, 0xC8, 0xC9, 0xFA, 0xC3, 0xC7, 0xA1, 0xB7,
      ]);
      final text = EncodingDetector.decodeChunked(bytes, EncodingType.gbk);
      expect(text, contains('奇怪的先生们'),
          reason: 'GBK 解码应还原中文，绝不能是 Latin-1 乱码');
      expect(text, contains('《'),
          reason: '书名号 A1B6/A1B7 应解码为《》而非乱码');
    });

    test('decodeChunked never throws on any encoding input', () {
      // 剪掉半个 GBK 字符（奇数截断）也不得抛出（闪退防护）。
      final odd = Uint8List.fromList([0xC6, 0xE6, 0xB9]); // 半个字符结尾
      expect(
        () => EncodingDetector.decodeChunked(odd, EncodingType.gbk),
        returnsNormally,
      );
      // Latin-1 高位单字节强制按 GBK 也应不抛（回退抓替换）
      final latin = Uint8List.fromList([0xE9, 0xE9, 0xE9]);
      expect(
        () => EncodingDetector.decodeChunked(latin, EncodingType.gbk),
        returnsNormally,
      );
    });
  });
}
