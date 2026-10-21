import 'dart:convert';
import 'dart:typed_data';

import 'package:charset/charset.dart' show gbk, shiftJis;
import 'package:gbk_codec/gbk_codec.dart' as gbkCodec;
import 'package:enough_convert/enough_convert.dart' as enoughGbk;

import '../domain/encoding_type.dart';
import '../../reader/reader_load_log.dart';

/// Sniff text encoding from raw bytes.
///
/// 优先级：
///   UTF-8 BOM → UTF-16 BOM → UTF-16 无 BOM 启发式
///   → UTF-8 严格 → 多字节候选（GBK / Shift-JIS 按解码可读性择优）
///   → unknown
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
    if (bytes.length >= 3 &&
        bytes[0] == 0xEF &&
        bytes[1] == 0xBB &&
        bytes[2] == 0xBF) {
      log.info(
          '[Enc] detect → utf8bom  耗时=${DateTime.now().difference(t0).inMilliseconds}ms');
      return EncodingType.utf8bom;
    }

    if (bytes.length >= 2) {
      if (bytes[0] == 0xFF && bytes[1] == 0xFE) {
        if (bytes.length >= 4 && bytes[2] == 0x00 && bytes[3] == 0x00) {
          log.info('[Enc] detect → unknown (UTF-32 LE 不支持)');
          return EncodingType.unknown;
        }
        log.info(
            '[Enc] detect → utf16le  耗时=${DateTime.now().difference(t0).inMilliseconds}ms');
        return EncodingType.utf16le;
      }
      if (bytes[0] == 0xFE && bytes[1] == 0xFF) {
        log.info(
            '[Enc] detect → utf16be  耗时=${DateTime.now().difference(t0).inMilliseconds}ms');
        return EncodingType.utf16be;
      }
    }

    // 2. UTF-16 无 BOM 启发式
    final tUtf16 = DateTime.now();
    final utf16Guess = _guessUtf16WithoutBom(bytes);
    if (utf16Guess != null) {
      log.info(
          '[Enc] detect → $utf16Guess (无 BOM 启发式)  启发耗时=${DateTime.now().difference(tUtf16).inMilliseconds}ms  总=${DateTime.now().difference(t0).inMilliseconds}ms');
      return utf16Guess;
    }

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

    // 4. 多字节编码候选
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

  /// Decode bytes using the detected encoding.
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
        // 使用多编码回退，防止单一解码器对扩展字符抛异常或静默错解。
        return _decodeGbkSafe(bytes);
      case EncodingType.shiftJis:
        return shiftJis.decode(bytes);
      case EncodingType.binary:
        return utf8.decode(bytes, allowMalformed: true);
      case EncodingType.unknown:
        return utf8.decode(bytes, allowMalformed: true);
    }
  }

  static const int _decodeChunkSize = 64 * 1024;

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
      case EncodingType.shiftJis:
        if (bytes.length <= _decodeChunkSize) {
          final result = _decodeLegacy(bytes: bytes, encoding: encoding);
          log.info(
              '[Enc] decodeChunked $encoding (小文件)  ${bytes.length}B → ${result.length} chars  耗时=${DateTime.now().difference(t0).inMilliseconds}ms');
          return result;
        }
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

  static String _decodeUtf16(Uint8List bytes, {required bool littleEndian}) {
    var start = 0;
    if (bytes.length >= 2) {
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

    if (evenRatio > 0.6 && oddRatio < 0.2) {
      return EncodingType.utf16be;
    }
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
        // 优先用 enough_convert 的 gbk（覆盖最全），流式更稳。
        return enoughGbk.gbk;
      case EncodingType.shiftJis:
        return shiftJis;
      default:
        return utf8;
    }
  }

  /// GBK 多编码回退解码。
  ///
  /// 三个包的 gbk 各有优缺点：
  ///   · enough_convert: 覆盖最全，不静默错解
  ///   · charset:        基础覆盖，普通中文稳
  ///   · gbk_codec:      遇非法字节**不抛异常**，静默按 Latin-1 转（坑）
  ///
  /// 每一步都用 `_looksLikeLatin1Garble` 拦住"静默错解"，
  /// 避免把 `ìÎÒÓÖ` 这种误导性结果当成成功解码返回。
  static String _decodeGbkSafe(Uint8List bytes) {
    // 1. enough_convert 的 gbk
    try {
      final r = enoughGbk.gbk.decode(bytes);
      if (r.isNotEmpty && !_looksLikeLatin1Garble(r)) return r;
    } catch (_) {}

    // 2. charset 的 gbk
    try {
      final r = gbk.decode(bytes);
      if (r.isNotEmpty && !_looksLikeLatin1Garble(r)) return r;
    } catch (_) {}

    // 3. gbk_codec 的 gbk
    try {
      final r = gbkCodec.gbk.decode(bytes);
      if (r.isNotEmpty && !_looksLikeLatin1Garble(r)) return r;
    } catch (_) {}

    // 4. utf8 容错兜底
    return utf8.decode(bytes, allowMalformed: true);
  }

  /// 判断解码结果是否"Latin-1 直译乱码"。
  /// 正常中文里 U+0080–U+00FF 几乎不出现；大量出现说明解码器把字节
  /// 直接当西欧字母转成字符，结果不可信。
  static bool _looksLikeLatin1Garble(String text) {
    if (text.isEmpty) return false;
    var total = 0;
    var latin1Range = 0;
    for (final r in text.runes) {
      total++;
      if (r >= 0x80 && r <= 0xFF) latin1Range++;
    }
    return latin1Range / total > 0.1;
  }

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
          return shiftJis.decode(bytes);
        default:
          return utf8.decode(bytes, allowMalformed: true);
      }
    } catch (_) {
      return utf8.decode(bytes, allowMalformed: true);
    }
  }

  // ==================== 原有启发式 ====================

  static bool _isStrictUtf8(Uint8List bytes) {
    try {
      utf8.decode(bytes);
      return true;
    } on FormatException {
      final s = utf8.decode(bytes, allowMalformed: true);
      var total = 0;
      var miss = 0;
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

  static int _plausibilityScore(Uint8List bytes, EncodingType encoding) {
    final String text;
    try {
      switch (encoding) {
        case EncodingType.gbk:
          text = enoughGbk.gbk.decode(bytes);
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
