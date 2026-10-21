import 'dart:convert';
import 'dart:typed_data';

import 'package:charset/charset.dart' show gbk, shiftJis;
import 'package:enough_convert/enough_convert.dart' as enoughGbk;

import '../domain/encoding_type.dart';
import '../../reader/reader_load_log.dart';

class EncodingDetector {
  const EncodingDetector._();
  static const int _sampleSize = 64 * 1024;

  static EncodingType detect(Uint8List bytes) {
    if (bytes.isEmpty) return EncodingType.ascii;

    // 1. BOM 检查
    if (bytes.length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) return EncodingType.utf8bom;
    if (bytes.length >= 2) {
      if (bytes[0] == 0xFF && bytes[1] == 0xFE) return EncodingType.utf16le;
      if (bytes[0] == 0xFE && bytes[1] == 0xFF) return EncodingType.utf16be;
    }

    final utf16Guess = _guessUtf16WithoutBom(bytes);
    if (utf16Guess != null) return utf16Guess;

    final sample = bytes.length <= _sampleSize ? bytes : Uint8List.sublistView(bytes, 0, _sampleSize);

    // 2. 严格 UTF-8 检测
    if (_isStrictUtf8(sample)) {
      final isAscii = bytes.every((b) => b < 0x80);
      return isAscii ? EncodingType.ascii : EncodingType.utf8;
    }

    // 3. 简体中文 App，只要像 GBK 就直接判为 GBK，彻底屏蔽 Shift-JIS 误判
    if (_looksLikeGbk(sample)) {
      return EncodingType.gbk;
    }

    return EncodingType.unknown;
  }

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
        return _decodeGbkSafe(bytes);
      case EncodingType.shiftJis:
        return shiftJis.decode(bytes);
      case EncodingType.binary:
      case EncodingType.unknown:
        return utf8.decode(bytes, allowMalformed: true);
    }
  }

  static const int _decodeChunkSize = 64 * 1024;

  static String decodeChunked(Uint8List bytes, EncodingType encoding) {
    switch (encoding) {
      case EncodingType.ascii:
      case EncodingType.utf8:
      case EncodingType.utf8bom:
      case EncodingType.utf16le:
      case EncodingType.utf16be:
      case EncodingType.binary:
      case EncodingType.unknown:
        return decode(bytes, encoding);
      case EncodingType.gbk:
      case EncodingType.gb18030:
        // 彻底抛弃流式分块解码，直接整体宽容解码，防止任何异常
        return _decodeGbkSafe(bytes);
      case EncodingType.shiftJis:
        return shiftJis.decode(bytes);
    }
  }

  static EncodingType? _guessUtf16WithoutBom(Uint8List bytes) {
    if (bytes.length < 8) return null;
    final n = bytes.length > 512 ? 512 : bytes.length;
    var evenZero = 0, oddZero = 0;
    final pairs = n ~/ 2;
    for (var i = 0; i + 1 < n; i += 2) {
      if (bytes[i] == 0) evenZero++;
      if (bytes[i + 1] == 0) oddZero++;
    }
    if (pairs < 4) return null;
    final evenRatio = evenZero / pairs;
    final oddRatio = oddZero / pairs;
    if (evenRatio > 0.6 && oddRatio < 0.2) return EncodingType.utf16be;
    if (oddRatio > 0.6 && evenRatio < 0.2) return EncodingType.utf16le;
    return null;
  }

  static String _decodeUtf16(Uint8List bytes, {required bool littleEndian}) {
    var start = 0;
    if (bytes.length >= 2) {
      if (littleEndian && bytes[0] == 0xFF && bytes[1] == 0xFE) start = 2;
      else if (!littleEndian && bytes[0] == 0xFE && bytes[1] == 0xFF) start = 2;
    }
    final codeUnits = <int>[];
    for (var i = start; i + 1 < bytes.length; i += 2) {
      final int cu = littleEndian ? (bytes[i] | (bytes[i + 1] << 8)) : ((bytes[i] << 8) | bytes[i + 1]);
      codeUnits.add(cu);
    }
    return String.fromCharCodes(codeUnits);
  }

  static String _decodeGbkSafe(Uint8List bytes) {
    // 1. 尝试用足够宽容的包整体解码
    try {
      final r = enoughGbk.gbk.decode(bytes);
      if (r.isNotEmpty && !_looksLikeTotalGarble(r)) return r;
    } catch (_) {}

    try {
      final r = gbk.decode(bytes);
      if (r.isNotEmpty && !_looksLikeTotalGarble(r)) return r;
    } catch (_) {}

    // 2. 如果整体失败（有生僻字导致抛异常），进入绝对安全的自定义状态机
    return _decodeGbkLenient(bytes);
  }

  static bool _looksLikeTotalGarble(String text) {
    if (text.isEmpty) return false;
    var total = 0, garble = 0;
    for (final r in text.runes) {
      total++;
      if (r >= 0x80 && r <= 0xFF) garble++;
    }
    return garble / total > 0.2;
  }

  /// 终极宽容解码：修复了错位 bug，哪怕遇到不认识的生僻字，也能完美跳过
  static String _decodeGbkLenient(Uint8List bytes) {
    final buf = StringBuffer();
    var i = 0;
    while (i < bytes.length) {
      final b = bytes[i];
      if (b < 0x80) {
        buf.writeCharCode(b);
        i++;
        continue;
      }
      
      if (i + 1 < bytes.length) {
        final b2 = bytes[i + 1];
        // 只要是合法的 GBK 双字节结构
        if (b >= 0x81 && b <= 0xFE && b2 >= 0x40 && b2 <= 0xFE && b2 != 0x7F) {
          try {
            final r = enoughGbk.gbk.decode(Uint8List.fromList([b, b2]));
            if (r.length == 1 && r.codeUnitAt(0) != 0xFFFD) {
              buf.write(r);
            } else {
              buf.writeCharCode(0xFFFD); // 实在不认识这个字，写 ?
            }
          } catch (_) {
            buf.writeCharCode(0xFFFD);
          }
          i += 2; // 核心修复：哪怕解不出来，也强行跳过两个字节，绝不破坏后续字节对齐！
          continue;
        }
      }
      // 既不是ASCII，也不是合法双字节，写 ? 并跳过 1 字节
      buf.writeCharCode(0xFFFD);
      i++;
    }
    return buf.toString();
  }

  static bool _isStrictUtf8(Uint8List bytes) {
    try {
      utf8.decode(bytes);
      return true;
    } on FormatException {
      final s = utf8.decode(bytes, allowMalformed: true);
      var total = 0, miss = 0;
      for (final r in s.runes) {
        if (r < 0x80) continue;
        total++;
        if (r == 0xFFFD) miss++;
      }
      if (total == 0) return true;
      return miss / total < 0.01;
    }
  }

  static bool _looksLikeGbk(Uint8List bytes) {
    int pairs = 0, loneHigh = 0, i = 0;
    while (i < bytes.length) {
      final b = bytes[i];
      if (b < 0x80) { i += 1; continue; }
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
}
