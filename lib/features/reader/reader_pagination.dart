import 'dart:math' as math;

import 'reader_models.dart';

// ==================== 固定排版常量 ====================
//
// 你说边距先写死，未来再改。这里是全局唯一来源。
// 想调边距/行距，改这四个常量就行。

const double kReaderHorizontalPadding = 12.0; // 左右各 12 像素
const double kReaderVerticalPadding = 8.0;    // 上下各 8 像素
const double kReaderLineHeightFactor = 1.4;   // 行距倍数
const double kReaderParaSpacing = 4.0;        // 段落间（空行）额外高度

// ==================== 主入口：分页 ====================

/// 把全文按屏幕高度切页。
///
/// 算法：字数估算。不逐行 TextPainter 精确测量——那样太慢。
/// 对小说场景足够准，误差量级 ±1 行。
PaginationResult paginate({
  required String text,
  required double viewportWidth,
  required double viewportHeight,
  required double fontSize,
  required int fontWeight,
}) {
  // 可用排版宽度（扣除左右 padding）
  final usableWidth =
      math.max(10.0, viewportWidth - kReaderHorizontalPadding * 2);
  // 可用排版高度（扣除上下 padding）
  final usableHeight =
      math.max(10.0, viewportHeight - kReaderVerticalPadding * 2);

  // 按 \n 切分（保留所有行，包括空行）
  final lines = _splitLines(text);
  final n = lines.length;

  final lineStarts = List<int>.filled(n, 0);
  final lineHeights = List<double>.filled(n, 0);
  final pageStarts = <int>[]..add(0);

  var charOffset = 0;
  var pageHeight = 0.0;

  for (var i = 0; i < n; i++) {
    final line = lines[i];
    lineStarts[i] = charOffset;

    final h = _estimateLineHeight(
      line: line,
      fontSize: fontSize,
      usableWidth: usableWidth,
    );
    lineHeights[i] = h;

    // 换页判断：加上这一行会超页高，且当前页不是空 → 开新页
    if (pageHeight + h > usableHeight && pageHeight > 0) {
      pageStarts.add(i);
      pageHeight = h;
    } else {
      pageHeight += h;
    }

    // 下一个字符偏移：这一行的长度 + 1 个 \n
    charOffset += line.length + 1;
  }

  return PaginationResult(
    pageStarts: pageStarts,
    lineStarts: lineStarts,
    lineHeights: lineHeights,
    totalChars: text.length,
  );
}

// ==================== 切行 ====================

/// 把文本按 \n 切。空文本返回 ['']。
/// 用索引遍历而不是 split()，避免为每一行额外分配 String 对象。
List<String> _splitLines(String text) {
  if (text.isEmpty) return const [''];
  final out = <String>[];
  var start = 0;
  for (var i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) == 0x0A) {
      out.add(text.substring(start, i));
      start = i + 1;
    }
  }
  // 最后一段（末尾没 \n 也要加）
  if (start <= text.length) {
    out.add(text.substring(start));
  }
  return out;
}

// ==================== 行宽估算 ====================
//
// 字符宽度估算（像素）：
//   半角空格：0.30 × fontSize
//   半角字母/数字：0.55 × fontSize
//   半角其它标点：0.50 × fontSize
//   CJK 汉字：1.00 × fontSize
//   其它（全角标点、假名、emoji 等）：0.70 × fontSize
//
// 这些系数是经验值，对小说场景足够准。误差在 ±10% 以内。

double _estimateLineWidth(String line, double fontSize) {
  if (line.isEmpty) return 0;
  var w = 0.0;
  for (final rune in line.runes) {
    if (rune < 0x80) {
      if (rune == 0x20) {
        w += fontSize * 0.30;
      } else if ((rune >= 0x30 && rune <= 0x39) || // 0-9
          (rune >= 0x41 && rune <= 0x5A) ||          // A-Z
          (rune >= 0x61 && rune <= 0x7A)) {          // a-z
        w += fontSize * 0.55;
      } else {
        w += fontSize * 0.50;
      }
    } else if (rune >= 0x4E00 && rune <= 0x9FFF) {
      w += fontSize * 1.0;  // CJK 常用汉字
    } else if (rune >= 0x3040 && rune <= 0x30FF) {
      w += fontSize * 1.0;  // 日文假名
    } else if (rune >= 0xAC00 && rune <= 0xD7AF) {
      w += fontSize * 1.0;  // 韩文
    } else {
      w += fontSize * 0.70; // 全角标点、其它
    }
  }
  return w;
}

// ==================== 行高估算 ====================

/// 估算一行显示需要的高度。
/// 若行宽超过可用宽度，会 wrap 成多显示行，高度按倍数算。
double _estimateLineHeight({
  required String line,
  required double fontSize,
  required double usableWidth,
}) {
  final baseLineHeight = fontSize * kReaderLineHeightFactor;

  // 空行：给一个基准高度（保留段落间距）
  if (line.isEmpty) {
    return baseLineHeight * 0.6 + kReaderParaSpacing;
  }

  final w = _estimateLineWidth(line, fontSize);
  // 至少 1 显示行
  final displayLines = math.max(1, (w / usableWidth).ceil());
  return displayLines * baseLineHeight;
}

// ==================== 页 / 偏移 转换 ====================

/// 给定字符偏移，找它在第几页。
int findPageForOffset(PaginationResult r, int charOffset) {
  if (r.lineStarts.isEmpty) return 0;
  // 二分：找最后一个 lineStarts[i] <= charOffset
  var lo = 0;
  var hi = r.lineStarts.length - 1;
  while (lo < hi) {
    final mid = (lo + hi + 1) >> 1;
    if (r.lineStarts[mid] <= charOffset) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  final lineIdx = lo;
  // 二分：找最后一个 pageStarts[i] <= lineIdx
  lo = 0;
  hi = r.pageStarts.length - 1;
  while (lo < hi) {
    final mid = (lo + hi + 1) >> 1;
    if (r.pageStarts[mid] <= lineIdx) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  return lo;
}

/// 给定页号，返回这一页第一行在全文的起始字符偏移。
int pageStartOffset(PaginationResult r, int pageIdx) {
  if (pageIdx < 0 || pageIdx >= r.pageStarts.length) return 0;
  return r.lineStarts[r.pageStarts[pageIdx]];
}

/// 给定页号，返回这一页的行范围 [startLine, endLine)。
({int startLine, int endLine}) pageLineRange(
    PaginationResult r, int pageIdx) {
  if (pageIdx < 0 || pageIdx >= r.pageStarts.length) {
    return (startLine: 0, endLine: 0);
  }
  final start = r.pageStarts[pageIdx];
  final end = pageIdx + 1 < r.pageStarts.length
      ? r.pageStarts[pageIdx + 1]
      : r.lineHeights.length;
  return (startLine: start, endLine: end);
}

// ==================== 查找关键词 ====================

/// 一条匹配。位置用"行内字符下标"，同时带"行号"和"全文偏移"方便跳转。
class KeywordMatch {
  const KeywordMatch({
    required this.lineIndex,
    required this.lineStartOffset,
    required this.startInLine,
    required this.endInLine,
  });

  final int lineIndex;
  final int lineStartOffset;
  final int startInLine;
  final int endInLine;

  int get globalStart => lineStartOffset + startInLine;
  int get globalEnd => lineStartOffset + endInLine;
}

/// 在全文里查关键词。逐行查，不跨行匹配。
List<KeywordMatch> findKeyword({
  required List<String> lines,
  required List<int> lineStarts,
  required String keyword,
}) {
  if (keyword.isEmpty) return const [];
  final out = <KeywordMatch>[];
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    var from = 0;
    while (from <= line.length - keyword.length) {
      final idx = line.indexOf(keyword, from);
      if (idx < 0) break;
      out.add(KeywordMatch(
        lineIndex: i,
        lineStartOffset: lineStarts[i],
        startInLine: idx,
        endInLine: idx + keyword.length,
      ));
      from = idx + keyword.length;
    }
  }
  return out;
}

// ==================== 高亮索引 ====================

/// 一条高亮在某一行的具体位置。
class HighlightSpan {
  const HighlightSpan({
    required this.startInLine,
    required this.endInLine,
    required this.entry,
  });

  final int startInLine;
  final int endInLine;
  final HighlightEntry entry;
}

/// 全部高亮的索引。按行号分组，渲染时 O(1) 拿到这一行的高亮。
class HighlightIndex {
  const HighlightIndex(this.byLine);

  /// key = 行号，value = 这一行的所有高亮区间（已排序、已去重）
  final Map<int, List<HighlightSpan>> byLine;

  List<HighlightSpan> forLine(int lineIdx) =>
      byLine[lineIdx] ?? const [];

  static const HighlightIndex empty = HighlightIndex({});
}

/// 构建高亮索引。
///
/// 规则：
///   · 逐行匹配（不跨行）
///   · 同一位置多个高亮命中 → 短的优先（用户 Q11）
///   · 结果按位置排序
HighlightIndex buildHighlightIndex({
  required List<String> lines,
  required List<HighlightEntry> highlights,
}) {
  if (highlights.isEmpty || lines.isEmpty) return HighlightIndex.empty;

  final byLine = <int, List<HighlightSpan>>{};

  for (final h in highlights) {
    if (h.keyword.isEmpty) continue;
    final key = h.keyword;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.isEmpty) continue;
      // 快速跳过：行长度比关键词还短，不可能匹配
      if (line.length < key.length) continue;

      var from = 0;
      while (from <= line.length - key.length) {
        final idx = line.indexOf(key, from);
        if (idx < 0) break;
        (byLine[i] ??= <HighlightSpan>[]).add(HighlightSpan(
          startInLine: idx,
          endInLine: idx + key.length,
          entry: h,
        ));
        from = idx + key.length;
      }
    }
  }

  // 每一行内：按位置排序 + 短词优先 + 去重叠
  for (final i in byLine.keys.toList()) {
    final list = byLine[i]!;
    list.sort((a, b) {
      final byStart = a.startInLine.compareTo(b.startInLine);
      if (byStart != 0) return byStart;
      // 同一起点，短的优先（区间长度升序）
      final lenA = a.endInLine - a.startInLine;
      final lenB = b.endInLine - b.startInLine;
      return lenA.compareTo(lenB);
    });
    // 去重叠：如果当前 span 的 start 小于上一个已保留的 end，跳过
    final kept = <HighlightSpan>[];
    var lastEnd = -1;
    for (final s in list) {
      if (s.startInLine < lastEnd) continue; // 与上一个重叠
      kept.add(s);
      lastEnd = s.endInLine;
    }
    byLine[i] = kept;
  }

  return HighlightIndex(byLine);
}

// ==================== 从整段文本构建行 / 行偏移（给外部复用） ====================

/// 分页时已经算过 lineStarts，但有时只有 text 没有 pagination 结果
/// （比如临时小文本）。这个函数单独提供。
({List<String> lines, List<int> lineStarts}) splitLinesWithOffsets(
    String text) {
  final lines = _splitLines(text);
  final offsets = List<int>.filled(lines.length, 0);
  var off = 0;
  for (var i = 0; i < lines.length; i++) {
    offsets[i] = off;
    off += lines[i].length + 1; // +1 是 \n
  }
  return (lines: lines, lineStarts: offsets);
}
