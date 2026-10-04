import 'dart:convert';
import 'dart:typed_data';

import 'package:charset/charset.dart';
import 'package:enough_convert/enough_convert.dart' hide gbk;
import 'package:gbk_codec/gbk_codec.dart' hide gbk;

import '../domain/encoding_type.dart';
import '../../reader/reader_load_log.dart';

/// Sniff text encoding from raw bytes.
///
/// 优先级：
///   UTF-8 BOM → UTF-16 BOM → UTF-16 无 BOM 启发式
///   → UTF-8 严格 → GBK → Big5 → Shift-JIS → unknown
class EncodingDetector {
  const EncodingDetector._();

  /// 编码探针采样窗（字节）。启发式判断只需看前缀，无需全文件扫描。
  static const int _sampleSize = 64 * 1024;

  static EncodingType detect(Uint8List bytes) {
    final log = ReaderLoadLog.instance;
    final t0 = DateTime.now();

    if (bytes.isEmpty) {
      log.info('[Enc] detect 空 bytes → ascii');
      return EncodingType.ascii;
    }

    // 1. BOM checks（必须用原文，BOM 只在文件头）
    // 顺序重要：先 UTF-8 BOM，再 UTF-16，再排除 UTF-32。
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      log.info(
          '[Enc] detect → utf8bom  耗时=${DateTime.now().difference(t0).inMilliseconds}ms');
      return EncodingType.utf8bom;
    }

    if (bytes.length >= 2) {
      // UTF-16 LE BOM: FF FE，但要排除 UTF-32 LE (FF FE 00 00)
      if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
        if (bytes.length >= 4 && bytes[2] == 0x00 && bytes[3] == 0x00) {
          log.info('[Enc] detect → unknown (UTF-32 LE 不支持)');
          return EncodingType.unknown;
        }
        log.info(
            '[Enc] detect → utf16le  耗时=${DateTime.now().difference(t0).inMilliseconds}ms');
        return EncodingType.utf16le;
      }
      // UTF-16 BE BOM: FE FF（UTF-32 BE 是 00 00 FE FF，不冲突）
      if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
        log.info(
            '[Enc] detect → utf16be  耗时=${DateTime.now().difference(t0).inMilliseconds}ms');
        return EncodingType.utf16be;
      }
    }

    // 2. UTF-16 无 BOM 启发式（必须在 UTF-8 之前！
    //    因为 UTF-16 里的 NUL 字节在 UTF-8 里是合法字符，
    //    会被 _isStrictUtf8 误判为 UTF-8）
    final tUtf16 = DateTime.now();
    final utf16Guess = _guessUtf16WithoutBom(bytes);
    if (utf16Guess != null) {
      log.info(
          '[Enc] detect → $utf16Guess (无 BOM 启发式)  启发耗时=${DateTime.now().difference(tUtf16).inMilliseconds}ms  总=${DateTime.now().difference(t0).inMilliseconds}ms');
      return utf16Guess;
    }

    // 采样前缀用于启发式判断（编码对全文一致，取前 64KB 判断足够，
    // 避免对大 TXT 全文反复 O(n) 扫描导致导入卡顿）。
    final sample = bytes.length <= _sampleSize
        ? bytes
        : Uint8List.sublistView(bytes, 0, _sampleSize);

    // 3. Strict UTF-8 trial
    final tUtf8 = DateTime.now();
    final isUtf8 = _isStrictUtf8(sample);
    log.info(
        '[Enc] _isStrictUtf8 耗时=${DateTime.now().difference(tUtf8).inMilliseconds}ms  结果=$isUtf8  sample=${sample.length}B');
    if (isUtf8) {
      final isAscii = bytes.every((b) => b < 0x80);
      log.info(
          '[Enc] detect → ${isAscii ? "ascii" : "utf8"}  总=${DateTime.now().difference(t0).inMilliseconds}ms');
      return isAscii ? EncodingType.ascii : EncodingType.utf8;
    }

    // 4. GB-family heuristic
    final tGbk = DateTime.now();
    final looksGbk = _looksLikeGbk(sample);
    final highMiss = looksGbk ? _isHighMissRate(sample) : false;
    log.info(
        '[Enc] GBK 检查  耗时=${DateTime.now().difference(tGbk).inMilliseconds}ms  looksGbk=$looksGbk  highMiss=$highMiss');
    if (looksGbk && highMiss) {
      log.info(
          '[Enc] detect → gbk  总=${DateTime.now().difference(t0).inMilliseconds}ms');
      return EncodingType.gbk;
    }

    // 5. Big5 heuristic
    final tBig5 = DateTime.now();
    final looksBig5 = _looksLikeBig5(sample);
    log.info(
        '[Enc] Big5 检查  耗时=${DateTime.now().difference(tBig5).inMilliseconds}ms  结果=$looksBig5');
    if (looksBig5) {
      log.info(
          '[Enc] detect → big5  总=${DateTime.now().difference(t0).inMilliseconds}ms');
      return EncodingType.big5;
    }

    // 6. Shift-JIS heuristic
    final tSjis = DateTime.now();
    final looksSjis = _looksLikeShiftJis(sample);
    log.info(
        '[Enc] SJIS 检查  耗时=${DateTime.now().difference(tSjis).inMilliseconds}ms  结果=$looksSjis');
    if (looksSjis) {
      log.info(
          '[Enc] detect → shiftJis  总=${DateTime.now().difference(t0).inMilliseconds}ms');
      return EncodingType.shiftJis;
    }

    log.info(
        '[Enc] detect → unknown  总=${DateTime.now().difference(t0).inMilliseconds}ms');
    return EncodingType.unknown;
  }

  /// Decode bytes using the detected encoding. Falls back to lossy UTF-8
  /// on illegal sequences.
  static String decode(Uint8List bytes, EncodingType encoding) {
    switch (encoding) {
      case EncodingType.ascii:
      case EncodingType.utf8:
        return utf8.decode(bytes, allowMalformed: true);
      case EncodingType.utf8bom:
        final skip = bytes.length >= 3 ? 3 : 0;
        return utf8.decode(bytes.sublist(skip), allowMalformed: true);
      case EncodingType.utf16le:
        return _decodeUtf16(bytes, littleEndian: true);
      case EncodingType.utf16be:
        return _decodeUtf16(bytes, littleEndian: false);
      case EncodingType.gbk:
      case EncodingType.gb18030:
        // dart:convert 无 GBK 解码器，使用第三方 gbk_codec 包。
        return gbk.decode(bytes);
      case EncodingType.big5:
        // dart:convert 无 Big5 解码器，使用第三方 enough_convert 包。
        return big5.decode(bytes);
      case EncodingType.shiftJis:
        // dart:convert 无 Shift-JIS 解码器，使用第三方 charset 包。
        return shiftJis.decode(bytes);
      case EncodingType.binary:
        return utf8.decode(bytes, allowMalformed: true);
      case EncodingType.unknown:
        // 未识别编码时按 UTF-8 容错解（byte 意图原样输出）。不强制回退 GBK，
        // 因为 ANSI 西文(Latin-1) 的高位字节若强当 GBK 会错解成中文乱码；
        // 中文 ANSI 实为 GBK，已被 detect 识别，无需在此兜底。
        return utf8.decode(bytes, allowMalformed: true);
    }
  }

  /// 分块窗口大小（字节）。用于大文本解码时避免一次性全量处理。
  static const int _decodeChunkSize = 64 * 1024;

  /// 按完整字符边界对齐的分块解码：GBK/Big5/Shift-JIS 都是
  /// `<0x80` 单字节 or `lead(0x80+) + 1 trail` 双字节结构，块尾若切开某个
  /// 双字节字符则把该 lead 字节留到下一块，保证每块解码跨块不乱码。
  ///
  /// UTF-16 也走一次性解码（有 BOM 处理，且字节长度必须偶数）；
  /// UTF-8 / ascii 也走一次性解码（内置快路径）。
  static String decodeChunked(Uint8List bytes, EncodingType encoding) {
    final log = ReaderLoadLog.instance;
    final t0 = DateTime.now();

    switch (encoding) {
      case EncodingType.ascii:
      case EncodingType.utf8:
      case EncodingType.utf8bom:
      case EncodingType.utf16le:
      case EncodingType.utf16be:
      case EncodingType.binary:
      case EncodingType.unknown:
        final result = decode(bytes, encoding);
        log.info(
            '[Enc] decodeChunked $encoding (一次性)  ${bytes.length}B → ${result.length} chars  耗时=${DateTime.now().difference(t0).inMilliseconds}ms');
        return result;
      case EncodingType.gbk:
      case EncodingType.gb18030:
      case EncodingType.big5:
      case EncodingType.shiftJis:
        // 小文件直接一次性解码，无跨块状态问题（更快且不会闪退）。
        if (bytes.length <= _decodeChunkSize) {
          final result = _decodeLegacy(bytes: bytes, encoding: encoding);
          log.info(
              '[Enc] decodeChunked $encoding (小文件)  ${bytes.length}B → ${result.length} chars  耗时=${DateTime.now().difference(t0).inMilliseconds}ms');
          return result;
        }
        // 大文件：用 stateful 流式解码器分块，解码器自身缓存跨块半个字符。
        // 任何异常都整体回退到逐块独立 decode（每块自洽，状态不会错乱），
        // 绝不继续向已污染的 sink 写入，避免异常传播导致闪退。
        log.info(
            '[Enc] decodeChunked $encoding (分块)  ${bytes.length}B  块大小=$_decodeChunkSize');
        final codec = _multiByteCodec(encoding);
        try {
          final buf = StringBuffer();
          final sink = codec.decoder.startChunkedConversion(
            StringConversionSink.fromStringSink(buf),
          ) as ByteConversionSink;
          var chunkCount = 0;
          for (var start = 0; start < bytes.length;) {
            final end = (start + _decodeChunkSize) > bytes.length
                ? bytes.length
                : start + _decodeChunkSize;
            sink.add(Uint8List.sublistView(bytes, start, end));
            start = end;
            chunkCount++;
          }
          sink.close();
          final result = buf.toString();
          log.info(
              '[Enc] decodeChunked $encoding 流式完成  块数=$chunkCount  ${result.length} chars  耗时=${DateTime.now().difference(t0).inMilliseconds}ms');
          return result;
        } catch (e) {
          // 整体回退：逐块独立解码并拼接，每个 chunk 是一个完整解码单元。
          log.info('[Enc] decodeChunked 流式失败 → 回退逐块  $e');
          final buf = StringBuffer();
          var chunkCount = 0;
          for (var start = 0; start < bytes.length;) {
            final end = (start + _decodeChunkSize) > bytes.length
                ? bytes.length
                : start + _decodeChunkSize;
            buf.write(_decodeLegacy(
              bytes: bytes.sublist(start, end),
              encoding: encoding,
            ));
            start = end;
            chunkCount++;
          }
          final result = buf.toString();
          log.info(
              '[Enc] decodeChunked $encoding 回退完成  块数=$chunkCount  ${result.length} chars  耗时=${DateTime.now().difference(t0).inMilliseconds}ms');
          return result;
        }
    }
  }

  // ==================== UTF-16 解码 ====================

  /// UTF-16 解码。自动处理 BOM（如果开头有的话），
  /// 剩下的按 2 字节一组组成 UTF-16 码元。
  /// `String.fromCharCodes` 接受含代理对的码元序列，
  /// 所以 BMP 和补充平面（emoji 等）都能正确解码。
  static String _decodeUtf16(Uint8List bytes, {required bool littleEndian}) {
    var start = 0;
    if (bytes.length >= 2) {
      // 跳过 BOM（如果存在）
      if (littleEndian && bytes[0] == 0xFF && bytes[1] == 0xFE) {
        start = 2;
      } else if (!littleEndian && bytes[0] == 0xFE && bytes[1] == 0xFF) {
        start = 2;
      }
    }

    final codeUnits = <int>[];
    for (var i = start; i + 1 < bytes.length; i += 2) {
      final int cu;
      if (littleEndian) {
        cu = bytes[i] | (bytes[i + 1] << 8);
      } else {
        cu = (bytes[i] << 8) | bytes[i + 1];
      }
      codeUnits.add(cu);
    }
    return String.fromCharCodes(codeUnits);
  }

  /// 无 BOM 的 UTF-16 启发式检测。
  ///
  /// 原理：ASCII 字符在 UTF-16 里高位字节是 0x00。
  ///   LE: 'a' = 61 00  → 奇数位是 0x00
  ///   BE: 'a' = 00 61  → 偶数位是 0x00
  /// 所以统计偶数位和奇数位的 0x00 占比即可。
  ///
  /// 触发条件：偶数位（或奇数位）中 0x00 占比 > 60%，
  /// 而另一侧 < 20%。这是保守阈值，不会误伤普通文本。
  static EncodingType? _guessUtf16WithoutBom(Uint8List bytes) {
    if (bytes.length < 8) return null;
    final n = bytes.length > 512 ? 512 : bytes.length;
    var evenZero = 0;
    var oddZero = 0;
    final pairs = n ~/ 2;
    for (var i = 0; i + 1 < n; i += 2) {
      if (bytes[i] == 0) evenZero++;
      if (bytes[i + 1] == 0) oddZero++;
    }
    if (pairs < 4) return null;

    final evenRatio = evenZero / pairs;
    final oddRatio = oddZero / pairs;

    // 偶数位大量 0x00 → BE
    if (evenRatio > 0.6 && oddRatio < 0.2) {
      return EncodingType.utf16be;
    }
    // 奇数位大量 0x00 → LE
    if (oddRatio > 0.6 && evenRatio < 0.2) {
      return EncodingType.utf16le;
    }
    return null;
  }

  // ==================== 第三方 codec 辅助 ====================

  static Encoding _multiByteCodec(EncodingType encoding) {
    switch (encoding) {
      case EncodingType.gbk:
      case EncodingType.gb18030:
        return gbk; // charset 的真双字节 GBK 解码器
      case EncodingType.big5:
        return big5;
      case EncodingType.shiftJis:
        return shiftJis;
      default:
        return utf8;
    }
  }

  static String _decodeLegacy({
    required Uint8List bytes,
    required EncodingType encoding,
  }) {
    try {
      switch (encoding) {
        case EncodingType.gbk:
        case EncodingType.gb18030:
          return gbk.decode(bytes);
        case EncodingType.big5:
          return big5.decode(bytes);
        case EncodingType.shiftJis:
          return shiftJis.decode(bytes);
        default:
          return utf8.decode(bytes, allowMalformed: true);
      }
    } catch (_) {
      // 任何第三方解码器对非法字节都可能抛 FormatException；这里逐字节
      // 原样输出码点，保证绝不闪退（保留原始字节意图）。
      return String.fromCharCodes(bytes);
    }
  }

  // ==================== 原有启发式（保持原样） ====================

  static bool _isStrictUtf8(Uint8List bytes) {
    try {
      utf8.decode(bytes);
      return true;
    } on FormatException {
      return false;
    }
  }

  /// 判断按 UTF-8 容错解码时替换符密度是否高。真 GBK 中文几乎每个字节都
  /// 错解成 U+FFFD；稀疏 ANSI 西文/近似 UTF-8 则替换符占比低，据此拒绝将其
  /// 误判为 GBK。
  static bool _isHighMissRate(Uint8List bytes) {
    if (bytes.isEmpty) return false;
    final s = utf8.decode(bytes, allowMalformed: true);
    var total = 0, miss = 0;
    // 仅统计非 ASCII frame（含多字节），ASCII 不算比例分母，避免英文多时
    // 稀释 miss 密度而拒绝真正的 GBK 中文。
    for (final r in s.runes) {
      if (r < 0x80) continue;
      total += 1;
      if (r == 0xFFFD) miss += 1;
    }
    if (total == 0) return false;
    return miss / total >= 0.5;
  }

  /// Heuristic: at least 50% of high bytes form valid GBK lead/trail pairs
  /// (lead 0x81–0xFE, trail 0x40–0xFE excluding 0x7F). 宽松阈值以覆盖混在
  /// 大量 ASCII（英文/数字/标点）中的 GBK 中文，过高阈值会漏判成 unknown。
  static bool _looksLikeGbk(Uint8List bytes) {
    int pairs = 0;
    int loneHigh = 0;
    int i = 0;
    while (i < bytes.length) {
      final b = bytes[i];
      if (b < 0x80) {
        i += 1;
        continue;
      }
      if (b >= 0x81 && b <= 0xFE && i + 1 < bytes.length) {
        final t = bytes[i + 1];
        if (t >= 0x40 && t <= 0xFE && t != 0x7F) {
          pairs += 1;
          i += 2;
          continue;
        }
      }
      loneHigh += 1;
      i += 1;
    }
    final total = pairs + loneHigh;
    if (total == 0) return false;
    return pairs / total >= 0.5;
  }

  /// Heuristic: at least 80% of high bytes form valid Big5 lead/trail pairs
  /// (lead 0x81–0xFE, trail 0x40–0x7E or 0xA1–0xFE).
  static bool _looksLikeBig5(Uint8List bytes) {
    int pairs = 0;
    int loneHigh = 0;
    int i = 0;
    while (i < bytes.length) {
      final b = bytes[i];
      if (b < 0x80) {
        i += 1;
        continue;
      }
      if (b >= 0x81 && b <= 0xFE && i + 1 < bytes.length) {
        final t = bytes[i + 1];
        final valid = (t >= 0x40 && t <= 0x7E) || (t >= 0xA1 && t <= 0xFE);
        if (valid) {
          pairs += 1;
          i += 2;
          continue;
        }
      }
      loneHigh += 1;
      i += 1;
    }
    final total = pairs + loneHigh;
    if (total == 0) return false;
    return pairs / total >= 0.8;
  }

  /// Heuristic: at least 80% of high bytes form valid Shift-JIS lead/trail
  /// pairs (lead 0x81–0x9F / 0xE0–0xEF, trail 0x40–0x7E / 0x80–0xFC).
  static bool _looksLikeShiftJis(Uint8List bytes) {
    int pairs = 0;
    int loneHigh = 0;
    int i = 0;
    while (i < bytes.length) {
      final b = bytes[i];
      if (b < 0x80) {
        i += 1;
        continue;
      }
      final isLead = (b >= 0x81 && b <= 0x9F) || (b >= 0xE0 && b <= 0xEF);
      if (isLead && i + 1 < bytes.length) {
        final t = bytes[i + 1];
        final valid = (t >= 0x40 && t <= 0x7E) || (t >= 0x80 && t <= 0xFC);
        if (valid) {
          pairs += 1;
          i += 2;
          continue;
        }
      }
      loneHigh += 1;
      i += 1;
    }
    final total = pairs + loneHigh;
    if (total == 0) return false;
    return pairs / total >= 0.8;
  }
}
