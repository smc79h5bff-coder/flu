import 'dart:convert';
import 'dart:typed_data';

import 'package:charset/charset.dart' show gbk, shiftJis;
import 'package:enough_convert/enough_convert.dart' as ec;
import 'package:gbk_codec/gbk_codec.dart' as gbkCodec;

import '../domain/encoding_type.dart';
import '../../reader/reader_load_log.dart';

/// 编码探测与解码。**正确优先，速度其次。**
///
/// 关键决策：
///   - GBK 系列解码用 gbk_codec 优先，不用 charset。charset 的 GBK 解码器
///     对某些字节序列会**静默错位**：不抛异常，但从某处开始连续解出错误的
///     汉字，直到遇到下一个 ASCII 字符才恢复对齐。表现为「一段连续乱码、
///     换行后又正常」。gbk_codec 是逐字节实现，不会静默错位。
///   - charset 只用于 _plausibilityScore 的快速打分（只是比较候选，
///     不需要绝对正确，只需要区分 GBK / Big5 / Shift-JIS）。
///   - 所有路径都保留 _decodeLenient 兜底：坏一个字符写 U+FFFD，
///     绝不 String.fromCharCodes（那会把整段字节当 Latin-1，产生
///     ìÎÒÓÖ 这种整段乱码）。
class EncodingDetector {
  const EncodingDetector._();

  static const int _sampleSize = 64 * 1024;
  static const int _decodeChunkSize = 64 * 1024;

  // ==================== 探测 ====================

  static EncodingType detect(Uint8List bytes) {
    final log = ReaderLoadLog.instance;
    final t0 = DateTime.now();

    if (bytes.isEmpty) return EncodingType.ascii;

    // 1. BOM
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      log.info('[Enc] detect → utf8bom');
      return EncodingType.utf8bom;
    }
    if (bytes.length >= 2) {
      if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
        if (bytes.length >= 4 && bytes[2] == 0x00 && bytes[3] == 0x00) {
          log.info('[Enc] detect → unknown (UTF-32 LE)');
          return EncodingType.unknown;
        }
        log.info('[Enc] detect → utf16le');
        return EncodingType.utf16le;
      }
      if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
        log.info('[Enc] detect → utf16be');
        return EncodingType.utf16be;
      }
    }

    // 2. UTF-16 无 BOM
    final utf16Guess = _guessUtf16WithoutBom(bytes);
    if (utf16Guess != null) {
      log.info('[Enc] detect → $utf16Guess (无 BOM)');
      return utf16Guess;
    }

    final sample = bytes.length <= _sampleSize
        ? bytes
        : Uint8List.sublistView(bytes, 0, _sampleSize);

    // 3. 严格 UTF-8
    if (_isStrictUtf8(sample)) {
      final isAscii = bytes.every((b) => b < 0x80);
      log.info('[Enc] detect → ${isAscii ? "ascii" : "utf8"}');
      return isAscii ? EncodingType.ascii : EncodingType.utf8;
    }

    // 4. 多字节候选：按字节结构筛，再按解码可读性打分择优。
    final looksGbk = _looksLikeGbk(sample);
    final looksBig5 = _looksLikeBig5(sample);
    final looksSjis = _looksLikeShiftJis(sample);
    final candidates = <EncodingType>[
      if (looksGbk) EncodingType.gbk,
      if (looksBig5) EncodingType.big5,
      if (looksSjis) EncodingType.shiftJis,
    ];
    log.info(
        '[Enc] 多字节候选  looksGbk=$looksGbk  looksBig5=$looksBig5  looksSjis=$looksSjis');

    if (candidates.isNotEmpty) {
      var best = candidates.first;
      var bestScore = _plausibilityScore(sample, best);
      for (var i = 1; i < candidates.length; i++) {
        final score = _plausibilityScore(sample, candidates[i]);
        if (score > bestScore) {
          best = candidates[i];
          bestScore = score;
        }
      }
      log.info(
          '[Enc] detect → $best  得分=$bestScore  总=${DateTime.now().difference(t0).inMilliseconds}ms');
      return best;
    }

    log.info('[Enc] detect → unknown');
    return EncodingType.unknown;
  }

  /// 候选评分。这里用 **charset**（快）而不是 gbk_codec（慢）：
  /// 打分只需要比较候选，不需要绝对正确，charset 的静默错位不影响
  /// 「GBK 出常用字 vs SJIS 出假名」这种粗粒度区分。
  static int _plausibilityScore(Uint8List bytes, EncodingType encoding) {
    String text;
    try {
      switch (encoding) {
        case EncodingType.gbk:
        case EncodingType.gb2312:
        case EncodingType.gb18030:
          text = gbk.decode(bytes);
          break;
        case EncodingType.big5:
          text = ec.big5.decode(bytes);
          break;
        case EncodingType.shiftJis:
          text = shiftJis.decode(bytes);
          break;
        default:
          return -999999;
      }
    } catch (_) {
      // charset 抛异常时，用逐字节宽容结果打分，不直接淘汰候选。
      try {
        text = _decodeLenient(bytes, encoding);
      } catch (_) {
        return -999999;
      }
    }
    if (text.isEmpty) return -999999;

    var score = 0;
    var total = 0;
    var replacement = 0;
    for (final r in text.runes) {
      total++;
      if (r == 0xFFFD) {
        replacement++;
        continue;
      }
      if (r < 0x80) {
        score += 1;
      } else if (_commonHan.contains(r)) {
        score += 3;
      } else if (r >= 0x4E00 && r <= 0x9FFF) {
        score += 1;
      } else if ((r >= 0x3000 && r <= 0x303F) ||
          (r >= 0xFF01 && r <= 0xFF5E) ||
          (r >= 0x2010 && r <= 0x2027)) {
        score += 1;
      } else if (r >= 0x80 && r <= 0xFF) {
        score -= 8;
      } else {
        score -= 2;
      }
    }
    if (total > 0) score -= (replacement * 10) ~/ total;
    return score;
  }

  // ==================== 解码入口 ====================

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
      case EncodingType.gb2312:
      case EncodingType.gb18030:
      case EncodingType.big5:
      case EncodingType.shiftJis:
        return _decodeSafe(bytes, encoding);
      case EncodingType.binary:
      case EncodingType.unknown:
        return utf8.decode(bytes, allowMalformed: true);
    }
  }

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
        final r = decode(bytes, encoding);
        log.info(
            '[Enc] decodeChunked $encoding (一次性)  ${bytes.length}B → ${r.length} chars  '
            '耗时=${DateTime.now().difference(t0).inMilliseconds}ms');
        return r;
      case EncodingType.gbk:
      case EncodingType.gb2312:
      case EncodingType.gb18030:
      case EncodingType.big5:
      case EncodingType.shiftJis:
        break;
    }

    if (bytes.length <= _decodeChunkSize) {
      final r = _decodeSafe(bytes, encoding);
      log.info(
          '[Enc] decodeChunked $encoding (单块)  ${bytes.length}B → ${r.length} chars  '
          '耗时=${DateTime.now().difference(t0).inMilliseconds}ms');
      return r;
    }

    // 分块：逐块独立解码，每块对双字节边界对齐。
    // 不用 startChunkedConversion —— 那个 API 返回 Sink<List<int>>，
    // 强转 ByteConversionSink 在 charset 实现里会抛 TypeError。
    final buf = StringBuffer();
    var chunkCount = 0;
    var start = 0;
    while (start < bytes.length) {
      var end = (start + _decodeChunkSize) > bytes.length
          ? bytes.length
          : start + _decodeChunkSize;
      // 块尾对齐：end-1 是 lead、end 是 trail 时，这个双字节字符正好被
      // 劈开。把 trail 划到下一块。
      if (end < bytes.length &&
          end > start &&
          _isDoubleByteLead(bytes[end - 1], encoding) &&
          _isDoubleByteTrail(bytes[end], encoding)) {
        end += 1;
      }
      buf.write(_decodeSafe(Uint8List.sublistView(bytes, start, end), encoding));
      chunkCount++;
      start = end;
    }
    final result = buf.toString();
    log.info(
        '[Enc] decodeChunked $encoding (分块)  块数=$chunkCount  ${result.length} chars  '
        '耗时=${DateTime.now().difference(t0).inMilliseconds}ms');
    return result;
  }

  // ==================== 宽容解码（核心） ====================

  /// 宽容解码：多级降级，保证不整段乱码。
  ///
  /// GBK 系列：
  ///   1. gbk_codec 整体解码（正确，可能慢）
  ///   2. charset 整体解码（快，但可能静默错位）——只在 gbk_codec 抛异常时
  ///   3. 逐字节宽容（坏一个字符，不坏整段）
  ///
  /// Big5 / Shift-JIS：
  ///   enough_convert / charset → 逐字节宽容
  static String _decodeSafe(Uint8List bytes, EncodingType encoding) {
    if (bytes.isEmpty) return '';

    switch (encoding) {
      case EncodingType.gbk:
      case EncodingType.gb2312:
      case EncodingType.gb18030:
        try {
          final r = gbkCodec.gbk.decode(bytes);
          if (r.isNotEmpty) return r;
        } catch (_) {}
        try {
          final r = gbk.decode(bytes);
          if (r.isNotEmpty) return r;
        } catch (_) {}
        return _decodeLenient(bytes, encoding);

      case EncodingType.big5:
        try {
          final r = ec.big5.decode(bytes);
          if (r.isNotEmpty) return r;
        } catch (_) {}
        return _decodeLenient(bytes, encoding);

      case EncodingType.shiftJis:
        try {
          final r = shiftJis.decode(bytes);
          if (r.isNotEmpty) return r;
        } catch (_) {}
        return _decodeLenient(bytes, encoding);

      default:
        return utf8.decode(bytes, allowMalformed: true);
    }
  }

  /// 逐字节宽容解码。
  ///
  /// - ASCII 直接输出
  /// - 合法双字节对 → 用 gbk_codec / enough_convert / charset 尝试解码
  /// - 解不出的双字节也跳 2 字节，保证后续字节对齐不错位
  /// - 非法字节 → 写 U+FFFD
  static String _decodeLenient(Uint8List bytes, EncodingType encoding) {
    final buf = StringBuffer();
    var i = 0;
    while (i < bytes.length) {
      final b = bytes[i];
      if (b < 0x80) {
        buf.writeCharCode(b);
        i++;
        continue;
      }
      if (i + 1 < bytes.length &&
          _isDoubleByteLead(b, encoding) &&
          _isDoubleByteTrail(bytes[i + 1], encoding)) {
        final b2 = bytes[i + 1];
        try {
          final pair = Uint8List.fromList([b, b2]);
          final r = _decodeSinglePair(pair, encoding);
          if (r.isNotEmpty && r.codeUnitAt(0) != 0xFFFD) {
            buf.write(r);
          } else {
            buf.writeCharCode(0xFFFD);
          }
        } catch (_) {
          buf.writeCharCode(0xFFFD);
        }
        i += 2;
        continue;
      }
      buf.writeCharCode(0xFFFD);
      i++;
    }
    return buf.toString();
  }

  static String _decodeSinglePair(Uint8List pair, EncodingType encoding) {
    switch (encoding) {
      case EncodingType.gbk:
      case EncodingType.gb2312:
      case EncodingType.gb18030:
        return gbkCodec.gbk.decode(pair);
      case EncodingType.big5:
        return ec.big5.decode(pair);
      case EncodingType.shiftJis:
        return shiftJis.decode(pair);
      default:
        return utf8.decode(pair, allowMalformed: true);
    }
  }

  // ==================== 双字节边界判定 ====================

  static bool _isDoubleByteLead(int b, EncodingType encoding) {
    switch (encoding) {
      case EncodingType.gbk:
      case EncodingType.gb2312:
      case EncodingType.gb18030:
      case EncodingType.big5:
        return b >= 0x81 && b <= 0xFE;
      case EncodingType.shiftJis:
        return (b >= 0x81 && b <= 0x9F) || (b >= 0xE0 && b <= 0xEF);
      default:
        return false;
    }
  }

  static bool _isDoubleByteTrail(int b, EncodingType encoding) {
    switch (encoding) {
      case EncodingType.gbk:
      case EncodingType.gb2312:
      case EncodingType.gb18030:
        return b >= 0x40 && b <= 0xFE && b != 0x7F;
      case EncodingType.big5:
        return (b >= 0x40 && b <= 0x7E) || (b >= 0xA1 && b <= 0xFE);
      case EncodingType.shiftJis:
        return (b >= 0x40 && b <= 0x7E) || (b >= 0x80 && b <= 0xFC);
      default:
        return false;
    }
  }

  // ==================== UTF-16 ====================

  static String _decodeUtf16(Uint8List bytes, {required bool littleEndian}) {
    var start = 0;
    if (bytes.length >= 2) {
      if (littleEndian && bytes[0] == 0xFF && bytes[1] == 0xFE) start = 2;
      else if (!littleEndian && bytes[0] == 0xFE && bytes[1] == 0xFF) start = 2;
    }
    final codeUnits = <int>[];
    for (var i = start; i + 1 < bytes.length; i += 2) {
      final int cu = littleEndian
          ? (bytes[i] | (bytes[i + 1] << 8))
          : ((bytes[i] << 8) | bytes[i + 1]);
      codeUnits.add(cu);
    }
    return String.fromCharCodes(codeUnits);
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

  // ==================== 检测启发式 ====================

  static bool _isStrictUtf8(Uint8List bytes) {
    try {
      utf8.decode(bytes);
      return true;
    } on FormatException {
      return false;
    }
  }

  static bool _looksLikeGbk(Uint8List bytes) {
    int pairs = 0, loneHigh = 0, i = 0;
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

  static bool _looksLikeBig5(Uint8List bytes) {
    int pairs = 0, loneHigh = 0, i = 0;
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

  static bool _looksLikeShiftJis(Uint8List bytes) {
    int pairs = 0, loneHigh = 0, i = 0;
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

  static final Set<int> _commonHan =
      '的一是在不了有和人这中大为上个国我以要他时来用们生到作地于出就分对成会可主发年动同工也能下过子说产种面而方后多定行学法所民得经十三之进着等部度家电力里如水化高自二理起小物现实加量都两体制机当使点从业本去把性好应开它合还因由其些然前外天政四日那社义事平形相全表间样与关各重新线内数正心反你明看原又么利比或但质气第向道命此变条只没结解问意建月公无系军很情者最立代想已通并提直题党程展五果料象员革位入常文总次品式活设及管特件长求老头基资边流路级少图山统接知较将组见计别她手角期根论运农指几九区强放决西被干做必战先回则任取据处队南给色光门即保治北造百规热领七海口东导器压志世金增争济阶油思术极交受联什认六共权收证改清己美再采转更单风切打白教速花带安场身车例真务具万每目至达走积示议声报斗完类八离华名确才科张信马节话米整空元况今集温传土许步群广石记需段研界拉林律叫且究观越织装影算低持音众书布复容儿须际商非验连断深难近矿千周委素技备半办青省列习响约支般史感劳便团往酸历市克何除消构府称太准精值号率族维划选标写存候毛亲快效斯院查江型眼王按格养易置派层片始却专状育厂京识适属圆包火住调满县局照参红细引听该铁价严'
          .runes
          .toSet();
}
