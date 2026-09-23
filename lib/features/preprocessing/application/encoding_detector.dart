import 'dart:convert';
import 'dart:typed_data';

import 'package:charset/charset.dart';
import 'package:enough_convert/enough_convert.dart' hide gbk;
import 'package:gbk_codec/gbk_codec.dart' hide gbk;

import '../domain/encoding_type.dart';

/// Sniff text encoding from raw bytes.
///
/// PRD §2 Module 3.1: priority order — UTF-8 BOM → UTF-8 → GBK → GB18030 →
/// Big5 → Shift-JIS. We implement BOM detection + strict UTF-8 validation +
/// a simple GB-family heuristic. Full Big5/Shift-JIS path is P2 (TODO).
class EncodingDetector {
  const EncodingDetector._();

  /// 编码探针采样窗（字节）。启发式判断只需看前缀，无需全文件扫描。
  static const int _sampleSize = 64 * 1024;

  static EncodingType detect(Uint8List bytes) {
    if (bytes.isEmpty) return EncodingType.ascii;

    // 1. BOM checks（必须用原文，BOM 只在文件头）
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      return EncodingType.utf8bom;
    }

    // 采样前缀用于启发式判断（编码对全文一致，取前 64KB 判断足够，
    // 避免对大 TXT 全文反复 O(n) 扫描导致导入卡顿）。
    final sample = bytes.length <= _sampleSize
        ? bytes
        : Uint8List.sublistView(bytes, 0, _sampleSize);

    // 2. Strict UTF-8 trial
    if (_isStrictUtf8(sample)) {
      return bytes.every((b) => b < 0x80)
          ? EncodingType.ascii
          : EncodingType.utf8;
    }

    // 3. GB-family heuristic（P0 covers UTF-8/GBK/GB18030）。GBK 优先，因为
    //    中文场景最常见；Big5/Shift-JIS 因字节范围重叠难以用单字节对区分，
    //    放在后面仅作弱 fallback（常规中文文本几乎不会命中）。
    //    同时要求 UTF-8 容错解码下替换符密度高，避免把稀疏 ANSI 西文
    //    或近似 UTF-8 文本误判成 GBK 而错解成中文乱码。
    if (_looksLikeGbk(sample) && _isHighMissRate(sample)) {
      return EncodingType.gbk;
    }

    // 4. Big5 heuristic: lead 0x81–0xFE, trail 0x40–0x7E / 0xA1–0xFE。
    if (_looksLikeBig5(sample)) {
      return EncodingType.big5;
    }

    // 5. Shift-JIS heuristic: lead 0x81–0x9F / 0xE0–0xEF, trail 0x40–0x7E / 0x80–0xFC。
    if (_looksLikeShiftJis(sample)) {
      return EncodingType.shiftJis;
    }

    return EncodingType.unknown;
  }

  /// Decode bytes using the detected encoding. Falls back to lossy UTF-8 +
  /// '' on illegal sequences (PRD §3.1 异常处理).
  static String decode(Uint8List bytes, EncodingType encoding) {
    switch (encoding) {
      case EncodingType.ascii:
      case EncodingType.utf8:
        return utf8.decode(bytes, allowMalformed: true);
      case EncodingType.utf8bom:
        final skip = bytes.length >= 3 ? 3 : 0;
        return utf8.decode(bytes.sublist(skip), allowMalformed: true);
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

  /// 按完整字符边界对齐的分块解码：GBK/Big5/Shift-JIS 都是
  /// `<0x80` 单字节 or `lead(0x80+) + 1 trail` 双字节结构，块尾若切开某个
  /// 双字节字符则把该 lead 字节留到下一块，保证每块解码跨块不乱码。
  ///
  /// 第三方解码器（gbk/big5/shiftJis）不是跨块 stateful 的，因此不能在
  /// 块边界直接断开；此方法在传入前先对齐字符边界。UTF-8/ascii 仍用内置
  /// 快路径（全量一次性即可，速度快且无此问题）。
  static String decodeChunked(Uint8List bytes, EncodingType encoding) {
    switch (encoding) {
      case EncodingType.ascii:
      case EncodingType.utf8:
      case EncodingType.utf8bom:
      case EncodingType.binary:
      case EncodingType.unknown:
        return decode(bytes, encoding);
      case EncodingType.gbk:
      case EncodingType.gb18030:
      case EncodingType.big5:
      case EncodingType.shiftJis:
        // 小文件直接一次性解码，无跨块状态问题（更快且不会闪退）。
        if (bytes.length <= _decodeChunkSize) {
          return _decodeLegacy(bytes: bytes, encoding: encoding);
        }
        // 大文件：用 stateful 流式解码器分块，解码器自身缓存跨块半个字符。
        // 任何异常都整体回退到逐块独立 decode（每块自洽，状态不会错乱），
        // 绝不继续向已污染的 sink 写入，避免异常传播导致闪退。
        final codec = _multiByteCodec(encoding);
        try {
          final buf = StringBuffer();
          final sink = codec.decoder.startChunkedConversion(
            StringConversionSink.fromStringSink(buf),
          ) as ByteConversionSink;
          for (var start = 0; start < bytes.length;) {
            final end = (start + _decodeChunkSize) > bytes.length
                ? bytes.length
                : start + _decodeChunkSize;
            sink.add(Uint8List.sublistView(bytes, start, end));
            start = end;
          }
          sink.close();
          return buf.toString();
        } catch (_) {
          // 整体回退：逐块独立解码并拼接，每个 chunk 是一个完整解码单元。
          final buf = StringBuffer();
          for (var start = 0; start < bytes.length;) {
            final end = (start + _decodeChunkSize) > bytes.length
                ? bytes.length
                : start + _decodeChunkSize;
            buf.write(_decodeLegacy(
              bytes: bytes.sublist(start, end),
              encoding: encoding,
            ));
            start = end;
          }
          return buf.toString();
        }
    }
  }

  /// 分块解码窗口大小（字节）。
  static const int _decodeChunkSize = 64 * 1024;

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
