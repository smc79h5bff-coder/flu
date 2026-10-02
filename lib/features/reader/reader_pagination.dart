import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../preprocessing/application/aho_corasick.dart';
import 'reader_models.dart';

// ==================== 固定排版常量 ====================

const double kReaderHorizontalPadding = 12.0;
const double kReaderVerticalPadding = 8.0;
const double kReaderLineHeightFactor = 1.4;
const double kReaderParaSpacing = 4.0;

// ==================== 分页调度器 ====================

/// 分页调度器：先秒开，再后台精修。
///
/// 三阶段：
///   1. [start] 同步跑一次**估算分页** → 立即有 [result] 可用
///   2. 后台分帧用 TextPainter **精确测量**每一行高度
///   3. 全部测完 → 用精确高度**重跑分页**，替换 [result]
///
/// 用户位置保持：精修前后用"当前页首字符偏移"锚定。
class ReaderPaginator extends ChangeNotifier {
  ReaderPaginator({
    required this.text,
    required this.viewportWidth,
    required this.viewportHeight,
    required this.fontSize,
    required this.fontWeight,
  });

  final String text;
  final double viewportWidth;
  final double viewportHeight;
  final double fontSize;
  final int fontWeight;

  // ---- 内部状态 ----
  late final List<String> _lines;
  late final List<int> _lineStarts;
  late final List<double> _estimatedHeights;
  late final List<double?> _preciseHeights;

  PaginationResult? _result;
  int _precisionProgress = 0;
  bool _disposed = false;

  /// 用户交互时暂停精测，交互结束后恢复。省电。
  bool _paused = false;

  /// 当前生效的分页结果。
  PaginationResult? get result => _result;

  /// 精测进度 0.0~1.0。
  double get precisionRatio =>
      _lines.isEmpty ? 1.0 : _precisionProgress / _lines.length;

  /// 精测是否已完成。
  bool get isPrecise => _precisionProgress >= _lines.length;

  /// 用户位置锚点。精修时用来保持位置。
  int? anchorCharOffset;

  // ==================== 启动 ====================

  /// 立即开始：同步估算分页 + 启动异步精测。
  void start() {
    final split = splitLinesWithOffsets(text);
    _lines = split.lines;
    _lineStarts = split.lineStarts;
    _estimatedHeights = List<double>.filled(_lines.length, 0);
    _preciseHeights = List<double?>.filled(_lines.length, null);

    final usableWidth =
        math.max(10.0, viewportWidth - kReaderHorizontalPadding * 2);
    for (var i = 0; i < _lines.length; i++) {
      _estimatedHeights[i] =
          _estimateLineHeight(_lines[i], fontSize, usableWidth);
    }

    // 阶段 1：估算分页，立即生效。
    _result = _buildResult(
      heightOf: (i) => _estimatedHeights[i],
      usePreciseSplit: false,
      tp: null,
      style: null,
    );
    notifyListeners();

    // 阶段 2：启动后台精测。
    _scheduleNextChunk();
  }

  /// 暂停精测。用户按下屏幕时调用。
  void pause() {
    _paused = true;
  }

  /// 恢复精测。用户停手后调用。
  void resume() {
    if (!_paused) return;
    _paused = false;
    if (_precisionProgress < _lines.length) {
      _scheduleNextChunk();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  // ==================== 精测（分帧） ====================

  /// 每帧测量的时间预算（毫秒）。60fps 下 16ms 是上限，
  /// 留一半给 UI 渲染，用 8ms 测量。
  static const int _chunkBudgetMs = 8;

  void _scheduleNextChunk() {
    if (_disposed || _paused) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (_disposed || _paused) return;
      _precisionChunk();
    });
  }

  void _precisionChunk() {
    if (_disposed || _paused) return;
    if (_precisionProgress >= _lines.length) return;

    final usableWidth =
        math.max(10.0, viewportWidth - kReaderHorizontalPadding * 2);
    final style = TextStyle(
      fontSize: fontSize,
      fontWeight: _toFontWeight(fontWeight),
      height: kReaderLineHeightFactor,
      color: const Color(0xFF222222),
    );
    final tp = TextPainter(textDirection: ui.TextDirection.ltr);

    final sw = Stopwatch()..start();
    while (_precisionProgress < _lines.length &&
        sw.elapsedMilliseconds < _chunkBudgetMs) {
      final i = _precisionProgress;
      final line = _lines[i];
      if (line.isEmpty) {
        // 空行：渲染时占一个空格，高度 = 单行高。
        _preciseHeights[i] = fontSize * kReaderLineHeightFactor;
      } else {
        tp.text = TextSpan(text: line, style: style);
        tp.layout(maxWidth: usableWidth);
        _preciseHeights[i] = tp.height;
      }
      _precisionProgress++;
    }

    // 全部测完 → 精修分页。
    if (_precisionProgress >= _lines.length) {
      _applyPrecision();
      return;
    }

    // 继续下一帧。
    _scheduleNextChunk();
  }

  void _applyPrecision() {
    if (_disposed) return;
    final style = TextStyle(
      fontSize: fontSize,
      fontWeight: _toFontWeight(fontWeight),
      height: kReaderLineHeightFactor,
      color: const Color(0xFF222222),
    );
    final tp = TextPainter(textDirection: ui.TextDirection.ltr);

    _result = _buildResult(
      heightOf: (i) => _preciseHeights[i] ?? _estimatedHeights[i],
      usePreciseSplit: true,
      tp: tp,
      style: style,
    );
    notifyListeners();
  }

  // ==================== 核心分页算法 ====================

  PaginationResult _buildResult({
    required double Function(int index) heightOf,
    required bool usePreciseSplit,
    TextPainter? tp,
    TextStyle? style,
  }) {
    final usableWidth =
        math.max(10.0, viewportWidth - kReaderHorizontalPadding * 2);
    final usableHeight =
        math.max(10.0, viewportHeight - kReaderVerticalPadding * 2);
    final singleLineHeight = fontSize * kReaderLineHeightFactor;

    final n = _lines.length;
    final renderUnits = <RenderUnit>[];
    final pageStarts = <int>[]..add(0);
    var pageHeight = 0.0;

    void place(RenderUnit unit) {
      if (pageHeight + unit.height > usableHeight && pageHeight > 0) {
        pageStarts.add(renderUnits.length);
        pageHeight = unit.height;
      } else {
        pageHeight += unit.height;
      }
      renderUnits.add(unit);
    }

    for (var i = 0; i < n; i++) {
      final line = _lines[i];
      final h = heightOf(i);

      // 一屏放得下 → 单个 unit。
      if (h <= usableHeight) {
        place(RenderUnit(
          lineIndex: i,
          charStart: 0,
          charEnd: line.length,
          height: h,
        ));
        continue;
      }

      // 超长行 → 拆分成多个 unit。
      final units = usePreciseSplit
          ? _splitLongLinePrecise(
              lineIndex: i,
              content: line,
              tp: tp!,
              style: style!,
              maxWidth: usableWidth,
              maxHeight: usableHeight,
            )
          : _splitLongLineEstimated(
              lineIndex: i,
              content: line,
              usableWidth: usableWidth,
              usableHeight: usableHeight,
              singleLineHeight: singleLineHeight,
            );

      for (final u in units) {
        place(u);
      }
    }

    return PaginationResult(
      pageStarts: pageStarts,
      renderUnits: renderUnits,
      lineStarts: _lineStarts,
      totalChars: text.length,
    );
  }
}

// ==================== 长行拆分 ====================

/// 精确拆分：用 TextPainter 的 computeLineMetrics，拿到每个显示行的字符范围。
List<RenderUnit> _splitLongLinePrecise({
  required int lineIndex,
  required String content,
  required TextPainter tp,
  required TextStyle style,
  required double maxWidth,
  required double maxHeight,
}) {
  tp.text = TextSpan(text: content, style: style);
  tp.layout(maxWidth: maxWidth);

  final metrics = tp.computeLineMetrics();
  if (metrics.length <= 1) {
    return [
      RenderUnit(
        lineIndex: lineIndex,
        charStart: 0,
        charEnd: content.length,
        height: tp.height,
      )
    ];
  }

  // 每个显示行对应的字符范围。
  final ranges = <({int start, int end, double height})>[];
  for (var i = 0; i < metrics.length; i++) {
    final m = metrics[i];
    final yMid = m.baseline + (m.ascent + m.descent) / 2;
    final posStart = tp.getPositionForOffset(Offset(0, yMid));
    final posEnd = tp.getPositionForOffset(Offset(maxWidth - 0.5, yMid));
    var s = posStart.offset;
    var e = posEnd.offset;
    if (e <= s) e = s + 1;
    if (s < 0) s = 0;
    if (e > content.length) e = content.length;
    ranges.add((start: s, end: e, height: m.height));
  }

  // 修正边界：连续覆盖整行。
  ranges[0] = (start: 0, end: ranges[0].end, height: ranges[0].height);
  for (var i = 1; i < ranges.length; i++) {
    final prevEnd = ranges[i - 1].end;
    var s = ranges[i].start;
    var e = ranges[i].end;
    if (s < prevEnd) s = prevEnd;
    if (e < s + 1) e = s + 1;
    if (e > content.length) e = content.length;
    ranges[i] = (start: s, end: e, height: ranges[i].height);
  }
  final last = ranges.length - 1;
  ranges[last] = (
    start: ranges[last].start,
    end: content.length,
    height: ranges[last].height,
  );

  // 按 maxHeight 分组。
  final units = <RenderUnit>[];
  var chunkStart = 0;
  var chunkHeight = 0.0;
  for (var i = 0; i < ranges.length; i++) {
    final r = ranges[i];
    if (chunkHeight + r.height > maxHeight && i > chunkStart) {
      units.add(RenderUnit(
        lineIndex: lineIndex,
        charStart: ranges[chunkStart].start,
        charEnd: ranges[i].start,
        height: chunkHeight,
      ));
      chunkStart = i;
      chunkHeight = r.height;
    } else {
      chunkHeight += r.height;
    }
  }
  if (chunkStart < ranges.length) {
    units.add(RenderUnit(
      lineIndex: lineIndex,
      charStart: ranges[chunkStart].start,
      charEnd: content.length,
      height: chunkHeight,
    ));
  }
  return units;
}

/// 估算拆分：按"每屏能放多少字符"切。精度差但够用。
List<RenderUnit> _splitLongLineEstimated({
  required int lineIndex,
  required String content,
  required double usableWidth,
  required double usableHeight,
  required double singleLineHeight,
}) {
  final charWidth = singleLineHeight / kReaderLineHeightFactor;
  final charsPerLine = (usableWidth / charWidth).floor();
  final linesPerPage = (usableHeight / singleLineHeight).floor();

  if (charsPerLine <= 0 || linesPerPage <= 0) {
    return [
      RenderUnit(
        lineIndex: lineIndex,
        charStart: 0,
        charEnd: content.length,
        height: singleLineHeight,
      )
    ];
  }

  final charsPerChunk = charsPerLine * linesPerPage;
  final units = <RenderUnit>[];
  var start = 0;
  while (start < content.length) {
    final end = math.min(start + charsPerChunk, content.length);
    final chunkLen = end - start;
    final displayLines = math.max(1, (chunkLen / charsPerLine).ceil());
    units.add(RenderUnit(
      lineIndex: lineIndex,
      charStart: start,
      charEnd: end,
      height: displayLines * singleLineHeight,
    ));
    start = end;
  }
  return units;
}

// ==================== 估算 ====================

double _estimateLineHeight(String line, double fontSize, double usableWidth) {
  final baseLineHeight = fontSize * kReaderLineHeightFactor;
  // 空行 = 一个完整行高（渲染时占一个空格）。
  if (line.isEmpty) return baseLineHeight;
  final w = _estimateLineWidth(line, fontSize);
  final displayLines = math.max(1, (w / usableWidth).ceil());
  return displayLines * baseLineHeight;
}

/// 估算一行文字的显示宽度（像素）。
double _estimateLineWidth(String line, double fontSize) {
  if (line.isEmpty) return 0;
  var w = 0.0;
  for (final rune in line.runes) {
    if (rune < 0x80) {
      if (rune == 0x20) {
        w += fontSize * 0.30;
      } else if ((rune >= 0x30 && rune <= 0x39) ||
          (rune >= 0x41 && rune <= 0x5A) ||
          (rune >= 0x61 && rune <= 0x7A)) {
        w += fontSize * 0.55;
      } else {
        // 半角标点，实际比 0.5 窄。
        w += fontSize * 0.40;
      }
    } else {
      // 汉字、假名、全角标点都占满一格。
      w += fontSize * 1.0;
    }
  }
  return w;
}

FontWeight _toFontWeight(int v) {
  switch (v) {
    case 100:
      return FontWeight.w100;
    case 200:
      return FontWeight.w200;
    case 300:
      return FontWeight.w300;
    case 400:
      return FontWeight.w400;
    case 500:
      return FontWeight.w500;
    case 600:
      return FontWeight.w600;
    case 700:
      return FontWeight.w700;
    case 800:
      return FontWeight.w800;
    case 900:
      return FontWeight.w900;
    default:
      return FontWeight.w400;
  }
}

// ==================== 页 / 偏移 转换 ====================

/// 给定页号，返回该页包含的 RenderUnit 索引范围 [startUnit, endUnit)。
({int startUnit, int endUnit}) pageUnitRange(
    PaginationResult r, int pageIdx) {
  if (pageIdx < 0 || pageIdx >= r.pageStarts.length) {
    return (startUnit: 0, endUnit: 0);
  }
  final start = r.pageStarts[pageIdx];
  final end = pageIdx + 1 < r.pageStarts.length
      ? r.pageStarts[pageIdx + 1]
      : r.renderUnits.length;
  return (startUnit: start, endUnit: end);
}

/// 给定页号，返回该页第一字符在全文的起始偏移。
int pageStartOffset(PaginationResult r, int pageIdx) {
  if (pageIdx < 0 || pageIdx >= r.pageStarts.length) return 0;
  final unitIdx = r.pageStarts[pageIdx];
  if (unitIdx >= r.renderUnits.length) return r.totalChars;
  final u = r.renderUnits[unitIdx];
  return r.lineStarts[u.lineIndex] + u.charStart;
}

/// 给定字符偏移，找它在第几页。
int findPageForOffset(PaginationResult r, int charOffset) {
  if (r.renderUnits.isEmpty) return 0;
  var lo = 0;
  var hi = r.renderUnits.length - 1;
  while (lo < hi) {
    final mid = (lo + hi + 1) >> 1;
    final u = r.renderUnits[mid];
    final uStart = r.lineStarts[u.lineIndex] + u.charStart;
    if (uStart <= charOffset) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  var pLo = 0;
  var pHi = r.pageStarts.length - 1;
  while (pLo < pHi) {
    final mid = (pLo + pHi + 1) >> 1;
    if (r.pageStarts[mid] <= lo) {
      pLo = mid;
    } else {
      pHi = mid - 1;
    }
  }
  return pLo;
}

// ==================== 切行 ====================

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
  if (start <= text.length) {
    out.add(text.substring(start));
  }
  return out;
}

({List<String> lines, List<int> lineStarts}) splitLinesWithOffsets(
    String text) {
  final lines = _splitLines(text);
  final offsets = List<int>.filled(lines.length, 0);
  var off = 0;
  for (var i = 0; i < lines.length; i++) {
    offsets[i] = off;
    off += lines[i].length + 1;
  }
  return (lines: lines, lineStarts: offsets);
}

// ==================== 查找关键词 ====================

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

class HighlightIndex {
  const HighlightIndex(this.byLine);

  final Map<int, List<HighlightSpan>> byLine;

  List<HighlightSpan> forLine(int lineIdx) =>
      byLine[lineIdx] ?? const [];

  static const HighlightIndex empty = HighlightIndex({});
}

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

  for (final i in byLine.keys.toList()) {
    final list = byLine[i]!;
    list.sort((a, b) {
      final byStart = a.startInLine.compareTo(b.startInLine);
      if (byStart != 0) return byStart;
      final lenA = a.endInLine - a.startInLine;
      final lenB = b.endInLine - b.startInLine;
      return lenA.compareTo(lenB);
    });
    final kept = <HighlightSpan>[];
    var lastEnd = -1;
    for (final s in list) {
      if (s.startInLine < lastEnd) continue;
      kept.add(s);
      lastEnd = s.endInLine;
    }
    byLine[i] = kept;
  }

  return HighlightIndex(byLine);
}

/// ==================== Aho-Corasick 高亮匹配 ====================
///
/// 相比 [buildHighlightIndex] 的 O(n×m) 逐关键词逐行扫描，
/// 这个版本用 AC 一次扫描整篇文本，复杂度降到 O(n + 匹配数)。
/// 50 个高亮 + 10MB 文件：10 秒 → 100ms。
///
/// 约束：
///   · 只做**逐行**匹配，跨行的匹配会被跳过（和原函数一致）
///   · 同位置多个命中时，短的优先（和原函数一致）
HighlightIndex buildHighlightIndexAho({
  required String text,
  required List<int> lineStarts,
  required List<HighlightEntry> highlights,
}) {
  if (highlights.isEmpty || text.isEmpty || lineStarts.isEmpty) {
    return HighlightIndex.empty;
  }

  // 收集有效关键词。
  final patterns = <String>[];
  final entryByPattern = <int, HighlightEntry>{};
  for (final h in highlights) {
    if (h.keyword.isEmpty) continue;
    patterns.add(h.keyword);
    entryByPattern[patterns.length - 1] = h;
  }
  if (patterns.isEmpty) return HighlightIndex.empty;

  final ac = AhoCorasick(
    patterns: patterns,
    replacements: List<String>.filled(patterns.length, ''),
    priorities: List<int>.generate(patterns.length, (i) => i),
  );

  final byLine = <int, List<HighlightSpan>>{};

  ac.findAllMatches(text, (start, end, pi) {
    // 找 start 所在的行。
    final lineIdx = _findLineIndexInStarts(lineStarts, start);
    if (lineIdx < 0) return;

    // 跨行匹配：丢弃。
    final nextLineStart =
        lineIdx + 1 < lineStarts.length ? lineStarts[lineIdx + 1] : text.length;
    final lineEnd = nextLineStart > 0 ? nextLineStart - 1 : text.length;
    if (end > lineEnd) return;

    final lineStart = lineStarts[lineIdx];
    (byLine[lineIdx] ??= <HighlightSpan>[]).add(HighlightSpan(
      startInLine: start - lineStart,
      endInLine: end - lineStart,
      entry: entryByPattern[pi]!,
    ));
  });

  // 每行内：按位置排序 + 短词优先 + 去重叠。
  for (final i in byLine.keys.toList()) {
    final list = byLine[i]!;
    list.sort((a, b) {
      final byStart = a.startInLine.compareTo(b.startInLine);
      if (byStart != 0) return byStart;
      final lenA = a.endInLine - a.startInLine;
      final lenB = b.endInLine - b.startInLine;
      return lenA.compareTo(lenB);
    });
    final kept = <HighlightSpan>[];
    var lastEnd = -1;
    for (final s in list) {
      if (s.startInLine < lastEnd) continue;
      kept.add(s);
      lastEnd = s.endInLine;
    }
    byLine[i] = kept;
  }

  return HighlightIndex(byLine);
}

/// lineStarts 是升序的，二分找最后一个 <= charOffset 的行。
int _findLineIndexInStarts(List<int> lineStarts, int charOffset) {
  if (lineStarts.isEmpty) return -1;
  var lo = 0;
  var hi = lineStarts.length - 1;
  while (lo < hi) {
    final mid = (lo + hi + 1) >> 1;
    if (lineStarts[mid] <= charOffset) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  return lo;
}
