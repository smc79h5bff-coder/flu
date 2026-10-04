
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'reader_load_log.dart';
import 'reader_models.dart';

// ==================== 固定排版常量 ====================


const double kReaderHorizontalPadding = 2.0;
const double kReaderVerticalPadding = 2.0;
const double kReaderLineHeightFactor = 1.0;
const double kReaderParaSpacing = 4.0;

// ==================== 分页调度器 ====================

/// 分页调度器：先秒开，再后台全量精修。
///
/// **核心思路**：所有行高都统一成 [_singleLineHeight] 的整数倍。
/// 分页时以"1 个显示行"为最小单位塞，塞不下就换页，
/// 所以每页底部最多留 1 行空白（通常是 0 行）。
///
/// 三阶段：
///   1. [start] 同步估算分页 → 秒开
///   2. 后台分帧精修：用 TextPainter 拿到每行的**显示行数**
///   3. 全部测完 → 用显示行数 × 单行高 重跑分页
class ReaderPaginator extends ChangeNotifier {
  ReaderPaginator({
  required this.text,
  required this.viewportWidth,
  required this.viewportHeight,
  required this.fontSize,
  required this.fontWeight,
  required this.pageBottomSafePx,
});

final String text;
final double viewportWidth;
final double viewportHeight;
final double fontSize;
final int fontWeight;

/// 分页底部安全边距（像素）。含义见 ReaderSettings.pageBottomSafePx。
final int pageBottomSafePx;

  late final List<String> _lines;
  late final List<int> _lineStarts;
  late final List<double?> _preciseHeights;

  PaginationResult? _result;
  bool _disposed = false;
  bool _paused = false;
  bool _chunkScheduled = false;

  int _precisionCursor = 0;

  /// 单行基准高度。所有行高都是它的整数倍。
  double _singleLineHeight = 0;

  static final TextPainter _precisionTP = TextPainter(
    textDirection: ui.TextDirection.ltr,
  );

  PaginationResult? get result => _result;
  int? anchorCharOffset;

  /// 精修进度 0.0~1.0。
  double get precisionRatio =>
      _lines.isEmpty ? 1.0 : _precisionCursor / _lines.length;

  // ==================== 统一测量样式 ====================

  /// 分页测量用的文本样式。
  ///
  /// **必须**和 reader_screen.dart 里 `_baseStyle` 完全一致，
  /// 否则测量宽度 ≠ 渲染宽度 → 溢出换行（表现为莫名其妙的换行、
  /// 一行被切成两行、或每行只剩几个字）。
  TextStyle _readerStyle() => TextStyle(
        fontSize: fontSize,
        fontWeight: _toFontWeight(fontWeight),
        height: kReaderLineHeightFactor,
        color: const Color(0xFF222222),
        letterSpacing: 0,
        wordSpacing: 0,
      );

  // ==================== 启动 ====================

  void start() {
    final log = ReaderLoadLog.instance;
    log.mark('paginator.start() 进入');

    final split = splitLinesWithOffsets(text);
    log.mark('paginator: splitLinesWithOffsets');
    log.info('lines = ${split.lines.length}');

    _lines = split.lines;
    _lineStarts = split.lineStarts;
    _preciseHeights = List<double?>.filled(_lines.length, null);
    log.mark('paginator: 分配 _preciseHeights');

    final style = _readerStyle();
    log.mark('paginator: 构造 _readerStyle');

    // 计算基准单行高度。
    // 用中英混合的参考串，取真实 layout 高度。
    final refTp = TextPainter(
      text: TextSpan(text: '中文Aa1，。', style: style),
      textDirection: ui.TextDirection.ltr,
    );
    refTp.layout();
    _singleLineHeight = refTp.height;
    log.mark('paginator: 测量单行基准高');
    log.info('singleLineHeight = ${_singleLineHeight.toStringAsFixed(2)}');

    // 立即给一个估算 result。
    _result = _buildResult();
    log.mark('paginator: 首次 _buildResult()');
    log.info('pages = ${_result?.pageCount}  units = ${_result?.renderUnits.length}');

    notifyListeners();
    log.mark('paginator: notifyListeners');

    _precisionCursor = 0;
    

// ⚠️ 精修（precision）已停用。停用原因：
//   · 首次分页已经用估算值给出了结果
//   · 精修只在屏幕有新帧时推进，静止看书几乎不跑
//   · 每次翻页会偷偷跑 2ms，长期耗电
//   · 对纯中文小说，估算和精确值差异 < 1 行
//
// 🔄 如需恢复：取消下面 _scheduleNextChunk() 的注释即可。
//    历史上曾因"底部空白过多/行被裁切"等问题开启精修；
//    恢复前先确认那些问题是否还会复现。
//
// _scheduleNextChunk();
    
    log.mark('paginator.start() 结束');
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  // ==================== 暂停 / 恢复 ====================

  void pause() {
    _paused = true;
  }

  void resume() {
    if (!_paused) return;
    _paused = false;
    if (_precisionCursor < _lines.length) {
      _scheduleNextChunk();
    }
  }

  /// 兼容 reader_screen 的调用。全量精修不使用窗口。
  void notifyVisiblePage(int pageIndex) {
    // no-op
  }

  // ==================== 精修（分帧） ====================

  /// 每帧精修时间预算（毫秒）。
  /// 2ms 让 CPU 峰值从 50% 降到 12%，显著省电。
  /// 精修总时间变长但用户不感知（后台任务）。
  static const int _chunkBudgetMs = 2;

  void _scheduleNextChunk() {
    if (_disposed || _paused) return;
    if (_chunkScheduled) return;
    _chunkScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _chunkScheduled = false;
      if (_disposed || _paused) return;
      _precisionChunk();
    });
  }

  void _precisionChunk() {
    if (_disposed || _paused) return;
    if (_precisionCursor >= _lines.length) return;

    final log = ReaderLoadLog.instance;
    final startCursor = _precisionCursor;

    final usableWidth =
        math.max(10.0, viewportWidth - kReaderHorizontalPadding * 2);
    final style = _readerStyle();
    final tp = _precisionTP;

    final sw = Stopwatch()..start();
    while (_precisionCursor < _lines.length &&
        sw.elapsedMilliseconds < _chunkBudgetMs) {
      final i = _precisionCursor;
      if (_preciseHeights[i] == null) {
        final line = _lines[i];
        if (line.isEmpty) {
          _preciseHeights[i] = _singleLineHeight;
        } else {
          tp.text = TextSpan(text: line, style: style);
          tp.layout(maxWidth: usableWidth);
          // 关键：用显示行数 × 单行高，保证所有行高都是基准整数倍。
          final displayLines = tp.computeLineMetrics().length;
          _preciseHeights[i] =
              math.max(1, displayLines) * _singleLineHeight;
        }
      }
      _precisionCursor++;
    }

    if (_precisionCursor >= _lines.length) {
      log.mark('precision 完成，总行数 ${_lines.length}');
      _applyPrecision();
      return;
    }

    // 只在每跨过 2000 行时打一次日志，避免刷屏。
    if ((startCursor ~/ 2000) != (_precisionCursor ~/ 2000)) {
      log.mark('precision 进度 ${_precisionCursor}/${_lines.length}');
    }

    _scheduleNextChunk();
  }

  void _applyPrecision() {
    if (_disposed) return;
    final log = ReaderLoadLog.instance;
    log.mark('_applyPrecision 开始');
    _result = _buildResult();
    log.mark('_applyPrecision 完成，重跑分页');
    log.info('pages = ${_result?.pageCount}  units = ${_result?.renderUnits.length}');
    notifyListeners();
    log.mark('_applyPrecision notifyListeners');
  }

  // ==================== 核心分页算法 ====================

  PaginationResult _buildResult() {
    final log = ReaderLoadLog.instance;
    final sw = Stopwatch()..start();

    final usableWidth =
        math.max(10.0, viewportWidth - kReaderHorizontalPadding * 2);

// 从可用高度里预留"底部安全边距"像素。
// floor() 的取整特性保证：只要除出来的商没跨过整数边界，
// 每页行数就不变。所以底部余量本来较大的页面完全不受影响，
// 只有底部余量 < pageBottomSafePx 的页面才会少一行——正是需要它的页面。
final usableHeight = math.max(
  10.0,
  viewportHeight - kReaderVerticalPadding * 2 - 10 - pageBottomSafePx,
);



    
    // 每页固定显示行数（以"1 个显示行"为单位）。
    final rowsPerPage = math.max(1, (usableHeight / _singleLineHeight).floor());

    final n = _lines.length;
    final renderUnits = <RenderUnit>[];
    final pageStarts = <int>[]..add(0);
    var rowsInPage = 0;

    final style = _readerStyle();
    final tp = _precisionTP;

    void place(RenderUnit unit, int rowCount) {
      if (rowsInPage + rowCount > rowsPerPage && rowsInPage > 0) {
        pageStarts.add(renderUnits.length);
        rowsInPage = 0;
      }
      renderUnits.add(unit);
      rowsInPage += rowCount;
    }

    var longLinesSplit = 0;
    var preciseLines = 0;
    var estimatedLines = 0;

    for (var i = 0; i < n; i++) {
      final line = _lines[i];
      final h = _preciseHeights[i] ?? _estimatedHeight(line, usableWidth);
      final rows = math.max(1, (h / _singleLineHeight).round());

      // 只有 1 个显示行的逻辑行才作为整体塞。
      // 更长的都拆，保证每个 unit 高度 ≤ 1 行，分页零留白。
      if (rows <= 1) {
        place(
          RenderUnit(
            lineIndex: i,
            charStart: 0,
            charEnd: line.length,
            height: rows * _singleLineHeight,
          ),
          rows,
        );
        continue;
      }

      // 多显示行的逻辑行：拆成多个 unit，每个 1 行高。
      longLinesSplit++;
      final isPrecise = _preciseHeights[i] != null;
      if (isPrecise) {
        preciseLines++;
      } else {
        estimatedLines++;
      }
      final units = isPrecise
          ? _splitLongLinePrecise(
              lineIndex: i,
              content: line,
              tp: tp,
              style: style,
              maxWidth: usableWidth,
              maxHeight: rowsPerPage * _singleLineHeight,
              singleLineHeight: _singleLineHeight,
            )
          : _splitLongLineEstimated(
              lineIndex: i,
              content: line,
              usableWidth: usableWidth,
              rowsPerPage: rowsPerPage,
              singleLineHeight: _singleLineHeight,
            );

      for (final u in units) {
        final uRows =
            math.max(1, (u.height / _singleLineHeight).round());
        place(u, uRows);
      }
    }

    log.mark(
        '_buildResult 完成 (${sw.elapsedMilliseconds}ms)  lines=$n units=${renderUnits.length} pages=${pageStarts.length} 长行拆分=$longLinesSplit(精确$preciseLines/估算$estimatedLines)');

    return PaginationResult(
      pageStarts: pageStarts,
      renderUnits: renderUnits,
      lineStarts: _lineStarts,
      totalChars: text.length,
    );
  }

  double _estimatedHeight(String line, double usableWidth) {
    if (line.isEmpty) return _singleLineHeight;
    final w = _estimateLineWidth(line, fontSize);
    final displayLines = math.max(1, (w / usableWidth).ceil());
    return displayLines * _singleLineHeight;
  }
}

// ==================== 长行拆分 ====================

List<RenderUnit> _splitLongLinePrecise({
  required int lineIndex,
  required String content,
  required TextPainter tp,
  required TextStyle style,
  required double maxWidth,
  required double maxHeight,
  required double singleLineHeight,
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
        height: singleLineHeight,
      )
    ];
  }

  final ranges = <({int start, int end})>[];
  for (var i = 0; i < metrics.length; i++) {
    final m = metrics[i];
    // 行中心 = baseline + (descent - ascent) / 2。
    // 写成 baseline + (ascent + descent) / 2 会偏高，落到上一行，
    // 导致切分点全错、渲染出奇怪的短行和空行。
    final yMid = m.baseline + (m.descent - m.ascent) / 2;
    final posStart = tp.getPositionForOffset(Offset(0, yMid));
    final posEnd = tp.getPositionForOffset(Offset(maxWidth - 0.5, yMid));
    var s = posStart.offset;
    var e = posEnd.offset;
    if (e <= s) e = s + 1;
    if (s < 0) s = 0;
    if (e > content.length) e = content.length;
    ranges.add((start: s, end: e));
  }

  ranges[0] = (start: 0, end: ranges[0].end);
  for (var i = 1; i < ranges.length; i++) {
    final prevEnd = ranges[i - 1].end;
    var s = ranges[i].start;
    var e = ranges[i].end;
    if (s < prevEnd) s = prevEnd;
    if (e < s + 1) e = s + 1;
    if (e > content.length) e = content.length;
    ranges[i] = (start: s, end: e);
  }
  final last = ranges.length - 1;
  ranges[last] = (start: ranges[last].start, end: content.length);

  // 每个 unit 最多 1 行高，分页零留白。
  const int maxRows = 1;
  final units = <RenderUnit>[];
  var chunkStart = 0;

  for (var i = 0; i < ranges.length; i++) {
    final wouldBe = i - chunkStart + 1;
    if (wouldBe > maxRows && i > chunkStart) {
      final rowCount = i - chunkStart;
      // charEnd 取"上一段的结尾"而不是"本段的开头"：
      // TextPainter 在某些标点挤压/避让场景下会留出字符 gap，
      // ranges[i].start 可能 > ranges[i-1].end。
      // 用 ranges[i-1].end 更稳，不会把上一行末尾和下一行开头之间
      // 的字符（可能是软换行点）拽进本 unit。
      units.add(RenderUnit(
        lineIndex: lineIndex,
        charStart: ranges[chunkStart].start,
        charEnd: ranges[i - 1].end,
        height: rowCount * singleLineHeight,
      ));
      chunkStart = i;
    }
  }
  if (chunkStart < ranges.length) {
    final rowCount = ranges.length - chunkStart;
    units.add(RenderUnit(
      lineIndex: lineIndex,
      charStart: ranges[chunkStart].start,
      charEnd: content.length,
      height: rowCount * singleLineHeight,
    ));
  }
  return units;
}

List<RenderUnit> _splitLongLineEstimated({
  required int lineIndex,
  required String content,
  required double usableWidth,
  required int rowsPerPage,
  required double singleLineHeight,
}) {
  final charWidth = singleLineHeight / kReaderLineHeightFactor;
  final charsPerLine = math.max(1, (usableWidth / charWidth).floor());
  // 每块 1 行。
  final charsPerChunk = charsPerLine;

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
      height: math.min(displayLines, 1) * singleLineHeight,
    ));
    start = end;
  }
  return units;
}

// ==================== 估算 ====================

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
        w += fontSize * 0.40;
      }
    } else {
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

int pageStartOffset(PaginationResult r, int pageIdx) {
  if (pageIdx < 0 || pageIdx >= r.pageStarts.length) return 0;
  final unitIdx = r.pageStarts[pageIdx];
  if (unitIdx >= r.renderUnits.length) return r.totalChars;
  final u = r.renderUnits[unitIdx];
  return r.lineStarts[u.lineIndex] + u.charStart;
}

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
