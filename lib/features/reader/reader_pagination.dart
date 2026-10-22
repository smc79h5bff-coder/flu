
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'reader_load_log.dart';
import 'reader_models.dart';

// ==================== 固定排版常量 ====================


const double kReaderHorizontalPadding = 20.0;
const double kReaderVerticalPadding = 8.0;
const double kReaderLineHeightFactor = 1.5;
const double kReaderParaSpacing = 8.0;

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
    required this.pageTopSafePx,
    required this.pageBottomSafePx,
    List<String>? preSplitLines,
    List<int>? preSplitLineStarts,
  })  : _preSplitLines = preSplitLines,
        _preSplitLineStarts = preSplitLineStarts;

  final String text;
  final double viewportWidth;
  final double viewportHeight;
  final double fontSize;
  final int fontWeight;

  /// 分页顶部安全边距（像素）。含义见 ReaderSettings.pageTopSafePx。
  final int pageTopSafePx;

  /// 分页底部安全边距（像素）。含义见 ReaderSettings.pageBottomSafePx。
  final int pageBottomSafePx;

  /// 调用方如果已经切好行，直接塞进来避免 start() 里再切一次。
  final List<String>? _preSplitLines;
  final List<int>? _preSplitLineStarts;

  // 从 `late final` 改为 `late` —— 允许 dispose 时把它们重置成 const []，
  // 让 GC 尽快回收大数组（切编码时旧 paginator 未及时 GC，内存峰值翻倍）。
  late List<String> _lines;
  late List<int> _lineStarts;
  late List<double?> _preciseHeights;

  PaginationResult? _result;
  bool _disposed = false;
  bool _paused = false;
  bool _chunkScheduled = false;

  int _precisionCursor = 0;

  /// 当前可见页。由 reader_screen 主动上报，_applyPrecision 重跑分页后
  /// 用它做锚点把用户"钉"回同一段文字。
  int _currentPage = 0;

  /// 缓存 _readerStyle() —— _buildResult / _precisionChunk 每行都要用它，
  /// 缓存能省掉每行一次 TextStyle 构造（几万行 × 每次 new 一个对象）。
  late final TextStyle _cachedStyle = _readerStyle();

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

    if (_preSplitLines != null && _preSplitLineStarts != null) {
      _lines = _preSplitLines!;
      _lineStarts = _preSplitLineStarts!;
      log.mark('paginator: 使用外部传入的切行结果');
    } else {
      final split = splitLinesWithOffsets(text);
      _lines = split.lines;
      _lineStarts = split.lineStarts;
      log.mark('paginator: 内部切行');
    }
    _preciseHeights = List<double?>.filled(_lines.length, null);
    _precisionCursor = 0;
    log.mark('paginator: 分配数组');

    final style = _cachedStyle;
    final refTp = TextPainter(
      text: TextSpan(text: '中文Aa1，。', style: style),
      textDirection: ui.TextDirection.ltr,
    );
    refTp.layout();
    _singleLineHeight = refTp.height;
    log.mark('paginator: 测量单行基准高');

    // ★ 立即用估算值出结果（秒开）。_buildResult() 里 null _preciseHeights[i]
    // 自动回退到 _estimatedHeight，保证 UI 立刻有内容。
    _result = _buildResult();
    notifyListeners();
    log.mark('paginator: 初版分页完成（估算）');

    // ★ 后台分帧精修，精修完自动 _applyPrecision() 重跑并保页。
    _scheduleNextChunk();
  }

  @override
  void dispose() {
    _disposed = true;
    _result = null;
    _preciseHeights.clear();
    _lines = const [];
    _lineStarts = const [];
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

  /// 记住用户当前可见页，精修后用字符偏移恢复。
  void notifyVisiblePage(int pageIndex) {
    _currentPage = pageIndex;
  }

  // ==================== 同步精修 ====================

  /// 一次性用 TextPainter 精确测量所有行高度。
  ///
  /// 和旧版分帧精修一样的测量逻辑，只是去掉了"每帧 2ms 预算"的调度——
  /// 全部同步跑完再继续 `_buildResult()`。
  void _preciseAllLines() {
    if (_lines.isEmpty) return;
    final usableWidth =
        math.max(10.0, viewportWidth - kReaderHorizontalPadding * 2);
    final style = _readerStyle();
    final tp = _precisionTP;

    for (var i = 0; i < _lines.length; i++) {
      if (_preciseHeights[i] != null) continue; // 已算过就跳过
      final line = _lines[i];
      if (line.isEmpty) {
        _preciseHeights[i] = _singleLineHeight;
      } else {
        tp.text = TextSpan(text: line, style: style);
        tp.layout(maxWidth: usableWidth);
        final displayLines = tp.computeLineMetrics().length;
        _preciseHeights[i] =
            math.max(1, displayLines) * _singleLineHeight;
      }
    }
  }

  // ==================== 精修（分帧，保留给 pause/resume 兼容；不再主动调） ====================

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
    final style = _cachedStyle;
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

    // 记住当前页对应的字符偏移，重跑分页后恢复位置。
    final oldResult = _result;
    final anchorOffset = (oldResult != null && oldResult.pageCount > 0)
        ? pageStartOffset(
            oldResult, _currentPage.clamp(0, oldResult.pageCount - 1))
        : 0;

    _result = _buildResult();
    log.mark('_applyPrecision 重跑分页完成');
    log.info('pages = ${_result?.pageCount}  units = ${_result?.renderUnits.length}');

    if (_result != null && _result!.pageCount > 0) {
      _currentPage = findPageForOffset(_result!, anchorOffset);
    }

    notifyListeners();
    log.mark('_applyPrecision notifyListeners');
  }

  // ==================== 核心分页算法 ====================

  PaginationResult _buildResult() {
    final log = ReaderLoadLog.instance;
    final sw = Stopwatch()..start();

    final usableWidth =
        math.max(10.0, viewportWidth - kReaderHorizontalPadding * 2);

    // 从可用高度里预留"顶部 + 底部安全边距"。
    // 负数相当于拓宽可用高度（会多显示内容，可能裁切首尾）。
    // floor() 的取整特性保证：只要除出来的商没跨过整数边界，
    // 每页行数就不变。所以余量本来就较大的页面完全不受影响。
    final usableHeight = math.max(
      10.0,
      viewportHeight -
          kReaderVerticalPadding * 2 -
          10 -
          pageTopSafePx -
          pageBottomSafePx,
    );

    // 每页固定显示行数（以"1 个显示行"为单位）。
    final rowsPerPage = math.max(1, (usableHeight / _singleLineHeight).floor());

    final n = _lines.length;
    final renderUnits = <RenderUnit>[];
    final pageStarts = <int>[]..add(0);
    var rowsInPage = 0;

    final style = _cachedStyle;
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
 
    
    
    
    // 用 x=0 探针拿到本行内一个位置，再用 getLineBoundary 精确拿本视觉行
// 的字符边界 [start, end)。
//
// 不用 getPositionForOffset(maxWidth - 0.5)：
//   那个 x 落在行末之外，Dart 会 snap 到最近字符位置。一旦落在换行点，
//   就跳到下一行首，导致本行边界多含下一行字符。多出的字符在渲染时
//   会被再换行一次 → 本行右侧留大空白 + 下伸被裁 + 长按选字偏上一行。
final probe = tp.getPositionForOffset(Offset(0, yMid));
final boundary = tp.getLineBoundary(probe);
var s = boundary.start;
var e = boundary.end;
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
  if (content.isEmpty) return const [];

  final fontSize = singleLineHeight / kReaderLineHeightFactor;

  final units = <RenderUnit>[];
  var lineStart = 0;      // codeUnit index
  var x = 0.0;            // 当前行已排宽度
  var cuIdx = 0;          // codeUnit 游标

  // 按 codeUnit 顺序走，对 surrogate pair（两个 codeUnit 组成一个 rune）
  // 宽度一次算两个，但 charEnd 必须落在第二个 codeUnit 之后。
  while (cuIdx < content.length) {
    final cu = content.codeUnitAt(cuIdx);
    final isLead = cu >= 0xD800 && cu <= 0xDBFF;

    final double w;
    final int consume;
    if (isLead && cuIdx + 1 < content.length) {
      final trail = content.codeUnitAt(cuIdx + 1);
      if (trail >= 0xDC00 && trail <= 0xDFFF) {
        // surrogate pair：一个 rune，宽度按汉字算
        w = fontSize; // 极罕见的 emoji 按整字宽估算即可
        consume = 2;
      } else {
        // 孤立 lead，不应该出现，保险起见跳过
        w = 0;
        consume = 1;
      }
    } else if (cu >= 0xDC00 && cu <= 0xDFFF) {
      // 孤立 trail，跳过
      w = 0;
      consume = 1;
    } else {
      w = _estimateCharWidth(cu, fontSize);
      consume = 1;
    }

    // 加上这个 rune 会超出 → 换行（至少要有 1 个字符才允许换）
    if (x + w > usableWidth && cuIdx > lineStart) {
      units.add(RenderUnit(
        lineIndex: lineIndex,
        charStart: lineStart,
        charEnd: cuIdx,           // 上一段到这里（含完整 rune）
        height: singleLineHeight,
      ));
      lineStart = cuIdx;
      x = 0.0;
    }
    x += w;
    cuIdx += consume;
  }

  if (lineStart < content.length) {
    units.add(RenderUnit(
      lineIndex: lineIndex,
      charStart: lineStart,
      charEnd: content.length,
      height: singleLineHeight,
    ));
  }
  return units;
}

double _estimateCharWidth(int codeUnit, double fontSize) {
  // ASCII 用 3:4 的字体特征值，中文字按整字宽。
  // 和 _estimateLineWidth 保持一致，避免同一字符两个估算器冲突。
  if (codeUnit < 0x80) {
    if (codeUnit == 0x20) return fontSize * 0.30;
    if ((codeUnit >= 0x30 && codeUnit <= 0x39) ||
        (codeUnit >= 0x41 && codeUnit <= 0x5A) ||
        (codeUnit >= 0x61 && codeUnit <= 0x7A)) {
      return fontSize * 0.55;
    }
    return fontSize * 0.40;
  }
  return fontSize * 1.0;
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
