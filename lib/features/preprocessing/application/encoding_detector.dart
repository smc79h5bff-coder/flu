import 'dart:convert';
import 'dart:typed_data';

import 'package:charset/charset.dart' show gbk, shiftJis;
import 'package:enough_convert/enough_convert.dart' as ec;

import '../domain/encoding_type.dart';
import '../../reader/reader_load_log.dart';

/// 编码探测与解码。**正确优先，速度其次。**
///
/// 核心原则：
///   1. 任何解码失败都降级到下一级宽容策略，绝不 String.fromCharCodes
///      把整段字节当 Latin-1 输出（那会产生 ìÎÒÓÖ 这种整段乱码）。
///   2. 分块时对齐双字节边界，块尾不劈开 lead/trail。
///   3. 宽容解码只坏单个字符（写 U+FFFD），不坏后续字节对齐。
///   4. 检测层：严格 UTF-8 → GBK → Big5 → Shift-JIS 打分择优，
///      不再因单个编码抛异常就淘汰候选。
class EncodingDetector {
  const EncodingDetector._();

  static const int _sampleSize = 64 * 1024;
  // ★ 先用 64MB 上限走一次性解码，排除分块逻辑的干扰。
  // 如果 charset 的 gbk.decode 本身没问题，一次性解应该正确（chars ≈ bytes/2）。
  // 如果一次性解也有 chars=bytes 的问题，说明 charset 包的 gbk 有 bug，
  // 需要换方案。
  static const int _decodeChunkSize = 64 * 1024 * 1024;

  // ==================== 探测 ====================

  static EncodingType detect(Uint8List bytes) {
    final log = ReaderLoadLog.instance;
    final t0 = DateTime.now();

    if (bytes.isEmpty) return EncodingType.ascii;

    // 1. BOM（必须用原文）
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      log.info('[Enc] detect → utf8bom');
      return EncodingType.utf8bom;
    }
    if (bytes.length >= 2) {
      if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
        // 排除 UTF-32 LE
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

    // 2. UTF-16 无 BOM 启发式（必须在 UTF-8 之前：UTF-16 的 NUL 字节
    //    在 UTF-8 里是合法字符，会骗过 _isStrictUtf8）
    final utf16Guess = _guessUtf16WithoutBom(bytes);
    if (utf16Guess != null) {
      log.info('[Enc] detect → $utf16Guess (无 BOM)');
      return utf16Guess;
    }

    final sample = bytes.length <= _sampleSize
        ? bytes
        : Uint8List.sublistView(bytes, 0, _sampleSize);

    // 3. 严格 UTF-8（字节级判断，不会被 sample 截断误判）
    if (_isStrictUtf8(sample)) {
      final isAscii = sample.every((b) => b < 0x80);
      log.info('[Enc] detect → ${isAscii ? "ascii" : "utf8"}');
      return isAscii ? EncodingType.ascii : EncodingType.utf8;
    }

    // 4. 多字节候选：先按字节结构筛，再按解码可读性打分择优。
    //    纯 GBK 文件不应因某个候选抛异常就被淘汰，所以这里用
    //    "宽容解码 + 打分" 而不是 "解码失败直接 -inf"。
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

  /// 候选编码的「可读性」打分：用宽容解码，统计字符分布。
  ///
  /// 关键：不用严格 decode。charset/enough_convert 对个别字节会抛异常，
  /// 严格 decode 一抛就把整个候选淘汰，纯 GBK 文件会被误判成 Shift-JIS
  /// 或 Big5。宽容解码让「一个坏字」不拖垮「整段判断」。
  static int _plausibilityScore(Uint8List bytes, EncodingType encoding) {
    final text = _decodeSafe(bytes, encoding);
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
        // Latin-1 补充区：正常中文文本几乎不出现，是错误解码的强信号
        score -= 8;
      } else {
        score -= 2;
      }
    }
    // 替换符密度惩罚
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
        return _decodeSafe(bytes, EncodingType.gbk);
      case EncodingType.big5:
        return _decodeSafe(bytes, EncodingType.big5);
      case EncodingType.shiftJis:
        return _decodeSafe(bytes, EncodingType.shiftJis);
      case EncodingType.binary:
      case EncodingType.unknown:
        return utf8.decode(bytes, allowMalformed: true);
    }
  }

  static String decodeChunked(Uint8List bytes, EncodingType encoding) {
    final log = ReaderLoadLog.instance;
    final t0 = DateTime.now();

    // 单字节编码 / UTF-16 / 未知，一次性解，无跨块问题。
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
        break; // 走下面的分块逻辑
    }

    if (bytes.length <= _decodeChunkSize) {
      final r = _decodeSafe(bytes, encoding);
      log.info(
          '[Enc] decodeChunked $encoding (单块)  ${bytes.length}B → ${r.length} chars  '
          '耗时=${DateTime.now().difference(t0).inMilliseconds}ms');
      return r;
    }

    // 分块：逐块独立解码，每块都对双字节边界对齐。
    // 不用 startChunkedConversion —— 那个 API 返回 Sink<List<int>>，
    // 强转 ByteConversionSink 在部分 charset 实现里会抛 TypeError。
    final buf = StringBuffer();
    var chunkCount = 0;
    var start = 0;
    while (start < bytes.length) {
      var end = (start + _decodeChunkSize) > bytes.length
          ? bytes.length
          : start + _decodeChunkSize;
      // 块尾对齐：如果 end-1 是 lead、end 是 trail，说明劈开了双字节字符，
      // 把 trail 划到下一块。
      if (end < bytes.length &&
          end > start &&
          _isDoubleByteLead(bytes[end - 1], encoding) &&
          _isDoubleByteTrail(bytes[end], encoding)) {
        end += 1;
      }
      // 块首对齐：如果 start 处是 trail（上一块末尾是 lead 但被切掉了），
      // 说明当前块开头不完整，跳过一个字节。
      if (start > 0 &&
          _isDoubleByteTrail(bytes[start], encoding) &&
          _isDoubleByteLead(bytes[start - 1], encoding)) {
        // 上一块的 lead 已随上一块解过，这里跳过孤 trail
        start += 1;
        if (start >= end) continue;
      }
      buf.write(_decodeSafe(
        Uint8List.sublistView(bytes, start, end),
        encoding,
      ));
      chunkCount++;
      start = end;
    }
    final result = buf.toString();
    log.info(
        '[Enc] decodeChunked $encoding (分块)  块数=$chunkCount  ${result.length} chars  '
        '耗时=${DateTime.now().difference(t0).inMilliseconds}ms');
    return result;
  }

  /// `decodeChunked` 的异步包装。
  /// 调用方（reader_screen、line_editor、single_file_editor、txt_parser）
  /// 统一 `await EncodingDetector.decodeChunkedAsync(bytes, encoding)`。
  static Future<String> decodeChunkedAsync(
      Uint8List bytes, EncodingType encoding) async {
    return decodeChunked(bytes, encoding);
  }

  // ==================== 宽容解码（核心） ====================

  /// 宽容解码：多级降级，保证不整段乱码、不闪退。
  ///
  /// 顺序：
  ///   1. 对应编码的严格 decode（最快）
  ///   2. 对应编码的逐字节宽容 decode（坏一个字符，不坏整段）
  ///   3. UTF-8 容错（最后兜底，至少不会把字节当 Latin-1 输出）
  static String _decodeSafe(Uint8List bytes, EncodingType encoding) {
    if (bytes.isEmpty) return '';

    final log = ReaderLoadLog.instance;

    // 1. 严格 decode
    try {
      String result;
      switch (encoding) {
        case EncodingType.gbk:
        case EncodingType.gb2312:
        case EncodingType.gb18030:
          result = gbk.decode(bytes);
          break;
        case EncodingType.big5:
          result = ec.big5.decode(bytes);
          break;
        case EncodingType.shiftJis:
          result = shiftJis.decode(bytes);
          break;
        default:
          result = utf8.decode(bytes);
      }
      // ★ 诊断日志：一次性 GBK 解码后 chars 数 vs bytes 数。
      // 正常 GBK 中文应该是 chars ≈ bytes/2（每汉字 2 字节）。
      // 如果 chars ≈ bytes，说明 charset 的 gbk.decode 有 bug（1:1 是 Latin-1 透传）。
      if (encoding == EncodingType.gbk ||
          encoding == EncodingType.gb2312 ||
          encoding == EncodingType.gb18030) {
        log.info(
          '[Enc-Diag] ${encoding.name}: input=${bytes.length}B → chars=${result.length} '
          'ratio=${(result.length / bytes.length).toStringAsFixed(3)} '
          '(${result.length < bytes.length * 0.75 ? "✓ 正常" : "⚠️ 异常 1:1 透传"})'
        );
      }
      return result;
    } catch (_) {
      // 继续降级
    }

    // 2. 逐字节宽容
    return _decodeLenient(bytes, encoding);
  }

  /// 逐字节宽容解码（分段版）。
  ///
  /// 不逐 pair decode（每对一次 decoder init，极慢）。
  /// 改成"连续合法区段整段 decode + 跳过非法字节"。
  static String _decodeLenient(Uint8List bytes, EncodingType encoding) {
    final buf = StringBuffer();
    var i = 0;
    var segStart = 0;

    void flush(int end) {
      if (end <= segStart) return;
      final sub = Uint8List.sublistView(bytes, segStart, end);
      try {
        buf.write(_decodeStrict(sub, encoding));
      } catch (_) {
        for (var k = segStart; k < end; k++) {
          buf.writeCharCode(0xFFFD);
        }
      }
    }

    while (i < bytes.length) {
      final b = bytes[i];
      if (b < 0x80) {
        i++;
        continue;
      }
      if (i + 1 < bytes.length &&
          _isDoubleByteLead(b, encoding) &&
          _isDoubleByteTrail(bytes[i + 1], encoding)) {
        i += 2;
        continue;
      }
      // 遇到非法字节：把 [segStart, i) 一次性 decode，跳过坏字节
      flush(i);
      buf.writeCharCode(0xFFFD);
      i++;
      segStart = i;
    }
    flush(bytes.length);
    return buf.toString();
  }

  /// 严格 decode（对应编码）。用于 _decodeLenient 里的区段 decode。
  static String _decodeStrict(Uint8List bytes, EncodingType encoding) {
    switch (encoding) {
      case EncodingType.gbk:
      case EncodingType.gb2312:
      case EncodingType.gb18030:
        return gbk.decode(bytes);
      case EncodingType.big5:
        return ec.big5.decode(bytes);
      case EncodingType.shiftJis:
        return shiftJis.decode(bytes);
      default:
        return utf8.decode(bytes);
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
    var i = 0;
    final n = bytes.length;
    while (i < n) {
      final b = bytes[i];
      if (b < 0x80) {
        i++;
        continue;
      }
      final int len;
      if ((b & 0xE0) == 0xC0) {
        len = 2;
      } else if ((b & 0xF0) == 0xE0) {
        len = 3;
      } else if ((b & 0xF8) == 0xF0) {
        len = 4;
      } else {
        return false; // 首字节非法
      }
      if (i + len > n) return true; // 尾部被 sample 截断，视为合法
      for (var k = 1; k < len; k++) {
        if ((bytes[i + k] & 0xC0) != 0x80) return false;
      }
      i += len;
    }
    return true;
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

  static bool _looksLikeBig5(Uint8List bytes) {
    int pairs = 0, loneHigh = 0, i = 0;
    while (i < bytes.length) {
      final b = bytes[i];
      if (b < 0x80) { i += 1; continue; }
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
      if (b < 0x80) { i += 1; continue; }
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

  /// 高频汉字集合（简体 + 繁体），用于 [_plausibilityScore]。
  static final Set<int> _commonHan =
      '的一是在不了有和人这中大为上个国我以要他时来用们生到作地于出就分对成会可主发年动同工也能下过子说产种面而方后多定行学法所民得经十三之进着等部度家电力里如水化高自二理起小物现实加量都两体制机当使点从业本去把性好应开它合还因由其些然前外天政四日那社义事平形相全表间样与关各重新线内数正心反你明看原又么利比或但质气第向道命此变条只没结解问意建月公无系军很情者最立代想已通并提直题党程展五果料象员革位入常文总次品式活设及管特件长求老头基资边流路级少图山统接知较将组见计别她手角期根论运农指几九区强放决西被干做必战先回则任取据处队南给色光门即保治北造百规热领七海口东导器压志世金增争济阶油思术极交受联什认六共权收证改清己美再采转更单风切打白教速花带安场身车例真务具万每目至达走积示议声报斗完类八离华名确才科张信马节话米整空元况今集温传土许步群广石记需段研界拉林律叫且究观越织装影算低持音众书布复容儿须际商非验连断深难近矿千周委素技备半办青省列习响约支般史感劳便团往酸历市克何除消构府称太准精值号率族维划选标写存候毛亲快效斯院查江型眼王按格养易置派层片始却专状育厂京识适属圆包火住调满县局照参红细引听该铁价严'
          .runes
          .toSet();
}
