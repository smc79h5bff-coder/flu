import 'dart:convert';
import 'dart:typed_data';

import 'package:charset/charset.dart' show gbk, shiftJis;
import 'package:gbk_codec/gbk_codec.dart' as gbkCodec;

import '../domain/encoding_type.dart';
import '../../reader/reader_load_log.dart';

/// 文本编码探测与解码。
///
/// 与旧版的关键差异：
///   1. decodeChunked 不再用 startChunkedConversion。那个 API 返回
///      `Sink<List<int>>`，强转 `ByteConversionSink` 在部分 charset 实现里会抛
///      TypeError，导致永远走回退。现在统一「逐块独立解码 + 双字节边界对齐」，
///      每块自洽，不依赖流式状态，也不会出现半字符。
///   2. 回退路径不再硬切 64KB。切块前检查块尾是否劈开了双字节字符。
///   3. _plausibilityScore 里 GBK 候选改用 gbk_codec 解码。charset 对部分
///      二级汉字抛异常，旧实现给 -999999 直接淘汰整个 GBK 候选，导致纯 GBK
///      文件被误判为 Shift-JIS。gbk_codec 不抛异常，正常打分。
///   4. _decodeGbkSafe 顺序：gbk_codec → charset → 逐字宽容。
///   5. 保留 Shift-JIS 候选。简体中文场景 GBK 会胜出，但日文 TXT 仍能识别。
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
          log.info('[Enc] detect → unknown (UTF-32 LE 不支持)');
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

    // 2. UTF-16 无 BOM（必须在 UTF-8 之前：UTF-16 的 NUL 字节在 UTF-8
    //    里是合法字符，会被 _isStrictUtf8 误判）
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

    // 4. 多字节候选评分
    final tMulti = DateTime.now();
    final looksGbk = _looksLikeGbk(sample);
    final looksSjis = _looksLikeShiftJis(sample);
    final candidates = <EncodingType>[
      if (looksGbk) EncodingType.gbk,
      if (looksSjis) EncodingType.shiftJis,
    ];
    log.info(
        '[Enc] 多字节候选  耗时=${DateTime.now().difference(tMulti).inMilliseconds}ms  '
        'looksGbk=$looksGbk  looksSjis=$looksSjis');

    if (candidates.isNotEmpty) {
      var best = candidates.first;
      var bestScore = _plausibilityScore(sample, best);
      log.info('[Enc] 候选 $best 得分=$bestScore');
      for (var i = 1; i < candidates.length; i++) {
        final score = _plausibilityScore(sample, candidates[i]);
        log.info('[Enc] 候选 ${candidates[i]} 得分=$score');
        if (score > bestScore) {
          best = candidates[i];
          bestScore = score;
        }
      }
      log.info(
          '[Enc] detect → $best  得分=$bestScore  总=${DateTime.now().difference(t0).inMilliseconds}ms');
      return best;
    }

    log.info(
        '[Enc] detect → unknown  总=${DateTime.now().difference(t0).inMilliseconds}ms');
    return EncodingType.unknown;
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
      case EncodingType.gb18030:
        return _decodeGbkSafe(bytes);
      case EncodingType.shiftJis:
        return _decodeSjisSafe(bytes);
      case EncodingType.big5:
        // 仅为通过穷尽性检查；Big5 不真正支持，按 UTF-8 宽容解码。
        return utf8.decode(bytes, allowMalformed: true);
      case EncodingType.binary:
      case EncodingType.unknown:
        return utf8.decode(bytes, allowMalformed: true);
    }
  }

  /// 分块解码：块间对齐双字节边界，每块独立解码。
  ///
  /// GBK / GB18030 / Shift-JIS 都是「< 0x80 单字节 / lead + trail 双字节」
  /// 结构，块尾可能切在一个字符的 lead 后面。检测到这种切法时把该 trail
  /// 顺延到下一块，两块各自解码就不会出现半字符乱码。
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
      case EncodingType.big5:
        return decode(bytes, encoding);

      case EncodingType.gbk:
      case EncodingType.gb18030:
      case EncodingType.shiftJis:
        if (bytes.length <= _decodeChunkSize) {
          final r = _decodeLegacy(bytes: bytes, encoding: encoding);
          log.info(
              '[Enc] decodeChunked $encoding (单块)  ${bytes.length}B → ${r.length} chars  '
              '耗时=${DateTime.now().difference(t0).inMilliseconds}ms');
          return r;
        }

        final buf = StringBuffer();
        var chunkCount = 0;
        var start = 0;
        while (start < bytes.length) {
          var end = (start + _decodeChunkSize) > bytes.length
              ? bytes.length
              : start + _decodeChunkSize;
          // 块尾对齐：如果 bytes[end-1] 是 lead、bytes[end] 是 trail，说明
          // 这里正好劈开了一个双字节字符。把 trail 划到下一块。
          if (end < bytes.length && end > start) {
            if (_isDoubleByteLead(bytes[end - 1], encoding) &&
                _isDoubleByteTrail(bytes[end], encoding)) {
              end += 1;
            }
          }
          buf.write(_decodeLegacy(
            bytes: Uint8List.sublistView(bytes, start, end),
            encoding: encoding,
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

  // ==================== 双字节边界判定 ====================

  static bool _isDoubleByteLead(int b, EncodingType encoding) {
    switch (encoding) {
      case EncodingType.gbk:
      case EncodingType.gb18030:
        return b >= 0x81 && b <= 0xFE;
      case EncodingType.shiftJis:
        return (b >= 0x81 && b <= 0x9F) || (b >= 0xE0 && b <= 0xEF);
      case EncodingType.big5:
        return false;
      default:
        return false;
    }
  }

  static bool _isDoubleByteTrail(int b, EncodingType encoding) {
    switch (encoding) {
      case EncodingType.gbk:
      case EncodingType.gb18030:
        return b >= 0x40 && b <= 0xFE && b != 0x7F;
      case EncodingType.shiftJis:
        return (b >= 0x40 && b <= 0x7E) || (b >= 0x80 && b <= 0xFC);
      case EncodingType.big5:
        return false;
      default:
        return false;
    }
  }

  // ==================== 解码辅助 ====================

  static String _decodeLegacy({
    required Uint8List bytes,
    required EncodingType encoding,
  }) {
    try {
      switch (encoding) {
        case EncodingType.gbk:
        case EncodingType.gb18030:
          return _decodeGbkSafe(bytes);
        case EncodingType.shiftJis:
          return _decodeSjisSafe(bytes);
        default:
          return utf8.decode(bytes, allowMalformed: true);
      }
    } catch (_) {
      return utf8.decode(bytes, allowMalformed: true);
    }
  }

  /// GBK 宽容解码：gbk_codec（最宽容）→ charset → 逐字宽容。
  ///
  /// gbk_codec 遇到不认识的字节不会抛异常，只会产出替换符或近似字符，
  /// 所以它是首选。charset 更规范但对部分二级汉字会抛异常，作为第二级。
  /// 两级都失败才落到逐字宽容——正常文件不会走到那里。
  static String _decodeGbkSafe(Uint8List bytes) {
    try {
      final r = gbkCodec.gbk.decode(bytes);
      if (r.isNotEmpty && !_looksLikeTotalGarble(r)) return r;
    } catch (_) {}

    try {
      final r = gbk.decode(bytes);
      if (r.isNotEmpty && !_looksLikeTotalGarble(r)) return r;
    } catch (_) {}

    return _decodeGbkLenient(bytes);
  }

  static String _decodeSjisSafe(Uint8List bytes) {
    try {
      final r = shiftJis.decode(bytes);
      if (r.isNotEmpty) return r;
    } catch (_) {}
    return _decodeSjisLenient(bytes);
  }

  /// 判断解码结果是否「明显错乱」。
  ///
  /// 只看 Latin-1 补充区（U+0080–U+00FF）的占比：正常中文 + 少量生僻字，
  /// 这个比例通常 < 5%；GBK 错位或 SJIS 解 GBK 会 > 50%。阈值 0.2 保守。
  static bool _looksLikeTotalGarble(String text) {
    if (text.isEmpty) return false;
    var total = 0, garble = 0;
    for (final r in text.runes) {
      total++;
      if (r >= 0x80 && r <= 0xFF) garble++;
    }
    return garble / total > 0.2;
  }

  /// 逐字宽容 GBK：解不出的双字节跳 2 字节，绝不破坏后续对齐。
  ///
  /// 只在 gbk_codec 和 charset 都失败时触发。每个双字节会分配一个
  /// Uint8List 并调一次 decode，成本不低；但这条路径本身很少走。
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
        if (b >= 0x81 && b <= 0xFE && b2 >= 0x40 && b2 <= 0xFE && b2 != 0x7F) {
          try {
            final r = gbkCodec.gbk.decode(Uint8List.fromList([b, b2]));
            if (r.length == 1 && r.codeUnitAt(0) != 0xFFFD) {
              buf.write(r);
            } else {
              buf.writeCharCode(0xFFFD);
            }
          } catch (_) {
            buf.writeCharCode(0xFFFD);
          }
          i += 2; // 关键：哪怕解不出也跳 2 字节，后续字符不会错位
          continue;
        }
      }
      buf.writeCharCode(0xFFFD);
      i++;
    }
    return buf.toString();
  }

  static String _decodeSjisLenient(Uint8List bytes) {
    final buf = StringBuffer();
    var i = 0;
    while (i < bytes.length) {
      final b = bytes[i];
      if (b < 0x80) {
        buf.writeCharCode(b);
        i++;
        continue;
      }
      final isLead = (b >= 0x81 && b <= 0x9F) || (b >= 0xE0 && b <= 0xEF);
      if (isLead && i + 1 < bytes.length) {
        final b2 = bytes[i + 1];
        final valid = (b2 >= 0x40 && b2 <= 0x7E) || (b2 >= 0x80 && b2 <= 0xFC);
        if (valid) {
          try {
            final r = shiftJis.decode(Uint8List.fromList([b, b2]));
            if (r.isNotEmpty) {
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
      }
      buf.writeCharCode(0xFFFD);
      i++;
    }
    return buf.toString();
  }

  // ==================== 检测启发式 ====================

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

  /// 候选评分。GBK 候选改用 gbk_codec 解码，不再因 charset 抛异常被淘汰。
  static int _plausibilityScore(Uint8List bytes, EncodingType encoding) {
    final String text;
    try {
      switch (encoding) {
        case EncodingType.gbk:
          text = gbkCodec.gbk.decode(bytes);
          break;
        case EncodingType.shiftJis:
          text = shiftJis.decode(bytes);
          break;
        default:
          return -999999;
      }
    } catch (_) {
      return -999999;
    }

    var score = 0;
    for (final r in text.runes) {
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
      } else {
        score -= 4;
      }
    }
    return score;
  }

  static final Set<int> _commonHan =
      '的一是在不了有和人这中大为上个国我以要他时来用们生到作地于出就分对成会可主发年动同工也能下过子说产种面而方后多定行学法所民得经十三之进着等部度家电力里如水化高自二理起小物现实加量都两体制机当使点从业本去把性好应开它合还因由其些然前外天政四日那社义事平形相全表间样与关各重新线内数正心反你明看原又么利比或但质气第向道命此变条只没结解问意建月公无系军很情者最立代想已通并提直题党程展五果料象员革位入常文总次品式活设及管特件长求老头基资边流路级少图山统接知较将组见计别她手角期根论运农指几九区强放决西被干做必战先回则任取据处队南给色光门即保治北造百规热领七海口东导器压志世金增争济阶油思术极交受联什认六共权收证改清己美再采转更单风切打白教速花带安场身车例真务具万每目至达走积示议声报斗完类八离华名确才科张信马节话米整空元况今集温传土许步群广石记需段研界拉林律叫且究观越织装影算低持音众书布复容儿须际商非验连断深难近矿千周委素技备半办青省列习响约支般史感劳便团往酸历市克何除消构府称太准精值号率族维划选标写存候毛亲快效斯院查江型眼王按格养易置派层片始却专状育厂京识适属圆包火住调满县局照参红细引听该铁价严'
      '這們個國為說時對學會來過發後裡經麼現當沒動進還樣開從實無與長機關點業將兩間問應戰頭體見產話內給門兒東聲員論處義幾認條氣題爾別變總電數報結務場計區隊決馬則聽達強難權設記類據邊張該規萬覺術領確傳師觀讓識帶導爭運飛風聯組濟車親極辦議證轉準單羅愛擊備連調質團價黨華級離亞請際約復線斷滿視須寫稱嗎輕農裝廣顯標談圖歷醫專費號盡較語僅隨選紅響雖勢參眾構節維劃敵陳態護興驗責營夠續講終緊黃絕項圍織鬥雙紀採舉殺蘇訴細願錢網熱屬臉職樂剛狀獨彈創錯蘭試腦預誰陽繼驚傷藥適衛險陸習勞財環納歡獲負雲遊龍樹層衝範異漢簡擔靜積餘檢靈協徵揮勝階審堅媽劉讀壓銀買養懷執亂幫歲優鐵稅藝陣腳惡塊頓島戶評寶釋顧貨歐換聞壞討麗監臨艦魚雜誤灣減編測敗夢溫劍漸貴槍樓縣畫遺謝魯慮銷鐘詩趕劇損舊錄葉鄉禮婦歸飯額順輸搖脫補謂療澤滅筆鮮詞聖擇尋廠煙諾倫奧賣載宮陰園謀榮孫頂鎮練爺館礎寧紙諸訓莊絲戲隱訪軟薩夥盤擴蓋億擁楊齊賽虛購揚綠貿畢輪庫跡競棄偉緩潛閃燈針絡純頁傑築鄭貝吳圓殘誠寬擺毀趙麥蔣讚紛違匯幣豐藍獻萊譯奪燒觸課牆襲罰俠廳側韓債慣猶掛獎紹縱訊徹烏瑪鏡煩簽傾鳥轟閉奮慶淚緣儀蟲駐橋嘆糧縮罷徑啟暫償橫憶鬧厲窮碼災膽辯曉勁貧輯賴潤遲輛廢淨兇礦診攝喪憑搶緒蕩綜壯掃礙詳凱顆罵賞貼憂戀嚇勵辭倆'
          .runes
          .toSet();
}
