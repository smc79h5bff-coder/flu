import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:share_plus/share_plus.dart';

import 'reader_loupe.dart';
import 'reader_models.dart';
import 'regex_highlight.dart';
import 'reader_search_provider.dart';

/// 滚动模式的阅读视图（正文层）。
///
/// 只负责"正文怎么滚 + 选区怎么选"。菜单、热区、悬浮按钮归 ReaderScreen。
///
/// 手势（在内部 GestureDetector(translucent) 上注册，不抢 Scrollable 的竖向滚动）：
///   · onTap                → 往下滚一屏（无动画）
///   · onHorizontalDragEnd  → 右滑往上滚一屏（无动画）
///   · onLongPressStart     → 开始选字
///   · onLongPressMoveUpdate→ 扩展选区
///   · onLongPressEnd       → 结束选字，显示操作栏
///   · 竖向拖动             → 交给 Scrollable（自由滚动）
///
/// 公开方法（供父级调用）：
///   · jumpToOffset(int charOffset)  跳到某个字符偏移
///   · jumpByScreen(int dir)         滚一屏（dir>0 往下，dir<0 往上）
class ReaderScrollView extends ConsumerStatefulWidget {
  const ReaderScrollView({
    super.key,
    required this.text,
    required this.lines,
    required this.lineStarts,
    required this.settings,
    required this.initialOffset,
    required this.highlights,
    required this.palettes,
    required this.onProgressChanged,
    required this.onHighlightAdded,
    required this.onPaletteEdit,
    this.onSelectionActiveChanged,
  });

  final String text;
  final List<String> lines;
  final List<int> lineStarts;
  final ReaderSettings settings;
  final int initialOffset;
  final List<HighlightEntry> highlights;
  final List<HighlightPalette> palettes;

  final void Function(int charOffset) onProgressChanged;
  final void Function(String word, HighlightPalette palette) onHighlightAdded;
  final void Function(int paletteIndex) onPaletteEdit;

  /// 选区状态变化回调。用于通知父级"滚动模式现在有/没有选中文字"，
  /// 父级据此禁用/淡出悬浮按钮，避免按钮盖住底部操作栏。
  final ValueChanged<bool>? onSelectionActiveChanged;

  @override
  ConsumerState<ReaderScrollView> createState() => ReaderScrollViewState();
}

class ReaderScrollViewState extends ConsumerState<ReaderScrollView> {
  late final ItemScrollController _scrollCtrl;
  late final ItemPositionsListener _positions;

  // ---- 选区 ----
  int? _selStartLine;
  int? _selStartOffset;
  int? _selEndLine;
  int? _selEndOffset;

  /// 0=不在拖，1=左（起点），2=右（终点）。
  int _draggingHandle = 0;
  Offset? _dragHandlePos;

  final Map<int, GlobalKey> _lineKeys = <int, GlobalKey>{};

  /// 整个滚动视图的 Stack。用于把行 / 手指的全局坐标转成 Stack 内局部
  /// 坐标，让手柄 / 放大镜的 Positioned 定位正确。
  final GlobalKey _stackKey = GlobalKey();

  // ---- 长按 / 边缘滚 ----
  bool _longPressActive = false;
  Offset? _longPressPos;
  Timer? _edgeScrollTimer;
  static const double _edgeThreshold = 80.0;
  static const int _edgeScrollIntervalMs = 80;

  // ---- 放大镜 ----
  Offset? _loupePos;

  // ---- 选区操作栏 ----
  bool _hBarVisible = false;

  // ---- 进度上报 ----
  int _lastReportedOffset = -1;

  // ---- 选区激活状态（用于通知父级）----
  bool _lastReportedSelectionActive = false;

  /// 选区统一色（手柄下方那条蓝，放大镜里也是它）。
  static const Color _selectionBg = Color(0x553D7CFF);

  @override
  void initState() {
    super.initState();
    _scrollCtrl = ItemScrollController();
    _positions = ItemPositionsListener.create();
    _positions.itemPositions.addListener(_onPositionsChanged);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      jumpToOffset(widget.initialOffset);
    });
  }

  @override
  void dispose() {
    _edgeScrollTimer?.cancel();
    _positions.itemPositions.removeListener(_onPositionsChanged);
    // 通知父级：选区没了。用 microtask 避开当前帧正在 dispose 的时机。
    final cb = widget.onSelectionActiveChanged;
    if (cb != null && _lastReportedSelectionActive) {
      Future.microtask(() => cb(false));
    }
    super.dispose();
  }

  // ==================== 公开方法 ====================

  /// 跳到某个字符偏移（二分找到对应行，再 jumpTo）。
  void jumpToOffset(int charOffset) {
    if (!_scrollCtrl.isAttached) return;
    if (widget.lineStarts.isEmpty) return;
    var lo = 0;
    var hi = widget.lineStarts.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (widget.lineStarts[mid] <= charOffset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    _scrollCtrl.jumpTo(index: lo);
  }

  /// 滚一屏。dir > 0 往下，dir < 0 往上。
  ///
  /// 下翻时，新顶部 = "当前屏幕底部所在的那一行"。
  /// 如果底部那一行只显示了一部分，它会在下一页顶部完整显示；
  /// 如果底部那一行已经完全可见，则从它的下一行开始。
  ///
  /// 上翻时，新顶部 = "当前屏幕顶部所在行 - 一屏可见行数"，
  /// 保证回翻时上一屏内容完整再现。
  void jumpByScreen(int dir) {
    if (!_scrollCtrl.isAttached) return;
    final positions = _positions.itemPositions.value;
    if (positions.isEmpty) return;

    final sorted = positions.toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    if (sorted.isEmpty) return;

    if (dir > 0) {
      // 找最后一个 itemLeadingEdge < 1 的 item —— 它的顶部还在视口内，
      // 意味着它要么完全可见，要么底部被裁。
      int? bottomRow;
      double bottomTrailing = 0;
      for (final p in sorted) {
        if (p.itemLeadingEdge < 1.0) {
          bottomRow = p.index;
          bottomTrailing = p.itemTrailingEdge;
        }
      }
      if (bottomRow == null) return;

      // trailing <= 1.0（含浮点容差）→ 完全可见 → 从下一行开始。
      // trailing >  1.0            → 部分可见 → 从它自身开始，
      //                             保证这半行会在下一页完整显示。
      final fullyVisible = bottomTrailing <= 1.0 + 1e-3;
      final target = fullyVisible ? bottomRow + 1 : bottomRow;
      final clamped = target.clamp(0, widget.lines.length - 1);
      _scrollCtrl.jumpTo(index: clamped);
      return;
    }

    // 上翻一屏：用第一个可见行往上退一屏。
    final first = sorted.first.index;
    final last = sorted.last.index;
    final visibleCount = last - first + 1;
    final target = (first - visibleCount).clamp(0, widget.lines.length - 1);
    _scrollCtrl.jumpTo(index: target);
  }

  // ==================== 进度上报 ====================

  void _onPositionsChanged() {
    final list = _positions.itemPositions.value;
    if (list.isEmpty) return;
    final first = list.reduce((a, b) => a.index < b.index ? a : b);
    final idx = first.index;
    if (idx < 0 || idx >= widget.lineStarts.length) return;
    final offset = widget.lineStarts[idx];
    if (offset != _lastReportedOffset) {
      _lastReportedOffset = offset;
      widget.onProgressChanged(offset);
    }
  }

  int? _firstVisibleLine() {
    final list = _positions.itemPositions.value;
    if (list.isEmpty) return null;
    return list.reduce((a, b) => a.index < b.index ? a : b).index;
  }

  int? _lastVisibleLine() {
    final list = _positions.itemPositions.value;
    if (list.isEmpty) return null;
    return list.reduce((a, b) => a.index > b.index ? a : b).index;
  }

  // ==================== 选区状态通知 ====================

  void _notifySelectionActive() {
    final active = _selStartLine != null || _selEndLine != null;
    if (active != _lastReportedSelectionActive) {
      _lastReportedSelectionActive = active;
      widget.onSelectionActiveChanged?.call(active);
    }
  }

  // ==================== 手势：点击 / 右滑 ====================

  void _handleTap() {
    if (_hBarVisible || _selStartLine != null) {
      setState(_clearSelection);
      return;
    }
    jumpByScreen(1);
  }

  void _handleHorizontalDragEnd(DragEndDetails d) {
    if (_hBarVisible || _selStartLine != null) return;
    final v = d.primaryVelocity ?? 0;
    if (v > 200) {
      jumpByScreen(-1);
    } else if (v < -200) {
      jumpByScreen(1);
    }
  }

  // ==================== 手势：长按选字 ====================

  void _handleLongPressStart(LongPressStartDetails d) {
    final hit = _hitTest(d.globalPosition);
    if (hit == null) return;

    // 选中一个"词"：中文一个字、英文一个单词、标点一个字符。
    final lineText = widget.lines[hit.line];
    final (from, to) = _wordRangeAt(lineText, hit.offset);

    _longPressActive = true;
    _longPressPos = d.globalPosition;
    _loupePos = d.globalPosition;

    setState(() {
      _selStartLine = hit.line;
      _selStartOffset = from;
      _selEndLine = hit.line;
      _selEndOffset = to;
      _hBarVisible = false;
    });

    _startEdgeScrollTimer();
    _notifySelectionActive();
  }

  /// 返回 [line] 内 offset 处的"词"范围 [from, to)。
  /// 规则：中文一个字；英文/数字连续一段；其它一个字符。
  (int, int) _wordRangeAt(String line, int offset) {
    if (line.isEmpty) return (0, 0);
    var o = offset.clamp(0, line.length - 1);
    final code = line.codeUnitAt(o);

    // 中文字符：选一个字
    if (code >= 0x4E00 && code <= 0x9FFF) {
      return (o, o + 1);
    }

    // 英文/数字/下划线：选连续一段
    bool isWordChar(int c) =>
        (c >= 0x30 && c <= 0x39) ||
        (c >= 0x41 && c <= 0x5A) ||
        (c >= 0x61 && c <= 0x7A) ||
        c == 0x5F;
    if (isWordChar(code)) {
      var s = o;
      var e = o + 1;
      while (s > 0 && isWordChar(line.codeUnitAt(s - 1))) {
        s--;
      }
      while (e < line.length && isWordChar(line.codeUnitAt(e))) {
        e++;
      }
      return (s, e);
    }

    // 其它：选一个字符
    return (o, o + 1);
  }

  void _handleLongPressMoveUpdate(LongPressMoveUpdateDetails d) {
    if (!_longPressActive) return;
    _longPressPos = d.globalPosition;
    _loupePos = d.globalPosition;

    final hit = _hitTest(d.globalPosition);
    if (hit != null) {
      setState(() {
        _selEndLine = hit.line;
        _selEndOffset = hit.offset;
      });
    } else {
      setState(() {});
    }
  }

  void _handleLongPressEnd(LongPressEndDetails d) {
    _longPressActive = false;
    _longPressPos = null;
    _loupePos = null;
    _edgeScrollTimer?.cancel();

    // 没选到任何东西 → 当普通点击处理
    if (_selStartLine == null || _selEndLine == null) {
      _clearSelection();
      _handleTap();
      return;
    }

    // 计算选中长度：跨行或同行内起止不同即视为"有选中"
    final sL = _selStartLine!;
    final eL = _selEndLine!;
    final sO = _selStartOffset ?? 0;
    final eO = _selEndOffset ?? 0;
    final hasSelection = sL != eL || sO != eO;

    if (!hasSelection) {
      // 极端情况：连一个字符都没选上 → 当点击
      setState(_clearSelection);
      _handleTap();
      return;
    }

    // 有选中 → 显示操作栏
    setState(() => _hBarVisible = true);
    _notifySelectionActive();
  }

  // ==================== 边缘自动滚 ====================

  void _startEdgeScrollTimer() {
    _edgeScrollTimer?.cancel();
    _edgeScrollTimer = Timer.periodic(
      const Duration(milliseconds: _edgeScrollIntervalMs),
      (_) => _tickEdgeScroll(),
    );
  }

  void _tickEdgeScroll() {
    if (!_longPressActive) return;
    final pos = _longPressPos;
    if (pos == null) return;
    if (!mounted) return;

    final screenH = MediaQuery.of(context).size.height;
    final dy = pos.dy;
    if (dy < _edgeThreshold) {
      _edgeScrollStep(-1);
    } else if (dy > screenH - _edgeThreshold) {
      _edgeScrollStep(1);
    }
  }

  void _edgeScrollStep(int dir) {
    if (!_scrollCtrl.isAttached) return;
    final first = _firstVisibleLine();
    final last = _lastVisibleLine();
    if (first == null || last == null) return;

    final int target;
    if (dir < 0) {
      if (first <= 0) return;
      target = first - 1;
    } else {
      if (last >= widget.lines.length - 1) return;
      target = last + 1;
    }
    _scrollCtrl.jumpTo(index: target);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_longPressActive) return;
      final p = _longPressPos;
      if (p == null) return;
      final hit = _hitTest(p);
      if (hit == null) return;
      setState(() {
        _selEndLine = hit.line;
        _selEndOffset = hit.offset;
      });
    });
  }

  // ==================== 选区计算 ====================

  ({int line, int offset})? _hitTest(Offset globalPos) {
    final list = _positions.itemPositions.value;
    final sorted = list.toList()..sort((a, b) => b.index.compareTo(a.index));
    for (final p in sorted) {
      final key = _lineKeys[p.index];
      final ctx = key?.currentContext;
      if (ctx == null) continue;
      final rp = ctx.findRenderObject();
      if (rp is! RenderParagraph) continue;
      final local = rp.globalToLocal(globalPos);
      final size = rp.size;
      if (local.dy < 0 || local.dy > size.height) continue;
      final clamped = Offset(
        local.dx.clamp(0.0, size.width),
        local.dy.clamp(0.0, size.height),
      );
      final pos = rp.getPositionForOffset(clamped);
      final lineText = widget.lines[p.index];
      return (
        line: p.index,
        offset: pos.offset.clamp(0, lineText.length),
      );
    }
    return null;
  }

  void _clearSelection() {
    _selStartLine = null;
    _selStartOffset = null;
    _selEndLine = null;
    _selEndOffset = null;
    _hBarVisible = false;
    _draggingHandle = 0;
    _dragHandlePos = null;
    _notifySelectionActive();
  }

  String _selectedText() {
    final sL = _selStartLine;
    final sO = _selStartOffset;
    final eL = _selEndLine;
    final eO = _selEndOffset;
    if (sL == null || sO == null || eL == null || eO == null) return '';

    var startL = sL, startO = sO, endL = eL, endO = eO;
    if (startL > endL || (startL == endL && startO > endO)) {
      final tL = startL, tO = startO;
      startL = endL;
      startO = endO;
      endL = tL;
      endO = tO;
    }

    if (startL == endL) {
      final line = widget.lines[startL];
      final s = startO.clamp(0, line.length);
      final e = endO.clamp(0, line.length);
      if (e <= s) return '';
      return line.substring(s, e);
    }
    final sb = StringBuffer();
    for (var i = startL; i <= endL; i++) {
      final line = widget.lines[i];
      if (i == startL) {
        sb.write(line.substring(startO.clamp(0, line.length)));
      } else if (i == endL) {
        sb.write('\n');
        sb.write(line.substring(0, endO.clamp(0, line.length)));
      } else {
        sb.write('\n');
        sb.write(line);
      }
    }
    return sb.toString();
  }

  // ==================== 手柄拖动 ====================

  void _handleDragStart(int which, Offset pos) {
    setState(() {
      _draggingHandle = which;
      _dragHandlePos = pos;
      _loupePos = pos;
      _hBarVisible = false;
    });
    _edgeScrollTimer?.cancel();
    _longPressActive = true;
    _longPressPos = pos;
    _startEdgeScrollTimer();
    _notifySelectionActive();
  }

  void _handleDragUpdate(Offset pos) {
    if (_draggingHandle == 0) return;
    _dragHandlePos = pos;
    _longPressPos = pos;
    _loupePos = pos;

    final hit = _hitTest(pos);
    if (hit != null) {
      setState(() {
        if (_draggingHandle == 1) {
          _selStartLine = hit.line;
          _selStartOffset = hit.offset;
        } else if (_draggingHandle == 2) {
          _selEndLine = hit.line;
          _selEndOffset = hit.offset;
        }
      });
    } else {
      setState(() {});
    }
  }

  void _handleDragEnd() {
    _draggingHandle = 0;
    _dragHandlePos = null;
    _longPressActive = false;
    _longPressPos = null;
    _loupePos = null;
    _edgeScrollTimer?.cancel();
    setState(() => _hBarVisible = true);
    _notifySelectionActive();
  }

  // ==================== 渲染 ====================

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    final bgColor = Color(s.bgColor);
    final baseStyle = TextStyle(
      fontSize: s.fontSize,
      fontWeight: _toFontWeight(s.fontWeight),
      height: 1.1,
      color: const Color(0xFF222222),
    );

    return ColoredBox(
      color: bgColor,
      child: Stack(
        key: _stackKey,
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onTap: _handleTap,
              onHorizontalDragEnd: _handleHorizontalDragEnd,
              onLongPressStart: _handleLongPressStart,
              onLongPressMoveUpdate: _handleLongPressMoveUpdate,
              onLongPressEnd: _handleLongPressEnd,
              child: ScrollablePositionedList.builder(
                itemScrollController: _scrollCtrl,
                itemPositionsListener: _positions,
                itemCount: widget.lines.length,
                padding: const EdgeInsets.symmetric(
                  horizontal: 4,
                  vertical: 2,
                ),
                itemBuilder: (ctx, i) {
                  final key = _lineKeys.putIfAbsent(i, () => GlobalKey());
                  final searchState = ref.watch(readerSearchProvider);
                  final searchHit =
                      (searchState.currentPos >= 0 &&
                              searchState.currentPos <
                                  searchState.hits.length)
                          ? searchState.hits[searchState.currentPos]
                          : null;
                  return _ScrollLineRow(
                    lineKey: key,
                    lineIndex: i,
                    text: widget.lines[i],
                    style: baseStyle,
                    highlights: widget.highlights,
                    inSelection: _isLineInSelection(i),
                    isSelStartLine: i == _selStartLine,
                    isSelEndLine: i == _selEndLine,
                    selStartOffset: _selStartOffset ?? 0,
                    selEndOffset: _selEndOffset ?? 0,
                    searchHit: (searchHit != null &&
                            searchHit.lineIndex == i)
                        ? (
                            start: searchHit.startInLine,
                            end: searchHit.endInLine,
                          )
                        : null,
                  );
                },
              ),
            ),
          ),

          ..._buildHandles(),

          if (_loupePos != null && _selStartLine != null)
            _buildLoupe(s, _loupePos!),

          if (_hBarVisible && _selStartLine != null && _selEndLine != null)
            _buildHBar(context, s),
        ],
      ),
    );
  }

  bool _isLineInSelection(int i) {
    final sL = _selStartLine;
    final eL = _selEndLine;
    if (sL == null || eL == null) return false;
    final lo = sL < eL ? sL : eL;
    final hi = sL < eL ? eL : sL;
    return i >= lo && i <= hi;
  }

  List<Widget> _buildHandles() {
    if (_selStartLine == null || _selEndLine == null) return const [];
    if (_hBarVisible == false && _draggingHandle == 0 && !_longPressActive) {
      return const [];
    }

    // 拿 Stack 的 RenderBox，把全局坐标转成 Stack 内局部坐标。
    // localToGlobal 给出的是全局坐标（含状态栏偏移），Positioned 要的是
    // Stack 内局部坐标，所以必须再 globalToLocal 转一次。
    final stackBox =
        _stackKey.currentContext?.findRenderObject() as RenderBox?;
    if (stackBox == null) return const [];

    final widgets = <Widget>[];

    // 左手柄：放在起点行的左上角外侧。
    final startKey = _lineKeys[_selStartLine!];
    final startCtx = startKey?.currentContext;
    if (startCtx != null) {
      final box = startCtx.findRenderObject() as RenderBox?;
      if (box != null) {
        final localTopLeft =
            stackBox.globalToLocal(box.localToGlobal(Offset.zero));
        widgets.add(
          Positioned(
            left: math.max(0, localTopLeft.dx - 20),
            top: localTopLeft.dy,
            child: _DragHandle(
              isLeft: true,
              onDragStart: (pos) => _handleDragStart(1, pos),
              onDragUpdate: _handleDragUpdate,
              onDragEnd: _handleDragEnd,
            ),
          ),
        );
      }
    }

    // 右手柄：放在终点行的右下角外侧。
    final endKey = _lineKeys[_selEndLine!];
    final endCtx = endKey?.currentContext;
    if (endCtx != null) {
      final box = endCtx.findRenderObject() as RenderBox?;
      if (box != null) {
        final localTopLeft =
            stackBox.globalToLocal(box.localToGlobal(Offset.zero));
        final size = box.size;
        widgets.add(
          Positioned(
            left: localTopLeft.dx + size.width,
            top: localTopLeft.dy + size.height - 28,
            child: _DragHandle(
              isLeft: false,
              onDragStart: (pos) => _handleDragStart(2, pos),
              onDragUpdate: _handleDragUpdate,
              onDragEnd: _handleDragEnd,
            ),
          ),
        );
      }
    }
    return widgets;
  }

  Widget _buildLoupe(ReaderSettings s, Offset fingerPos) {
    final line = _draggingHandle == 1
        ? _selStartLine
        : (_draggingHandle == 2 ? _selEndLine : _selEndLine);
    final offset = _draggingHandle == 1
        ? _selStartOffset
        : (_draggingHandle == 2 ? _selEndOffset : _selEndOffset);
    if (line == null || offset == null) return const SizedBox.shrink();
    if (line < 0 || line >= widget.lines.length) {
      return const SizedBox.shrink();
    }

    final lineText = widget.lines[line];

    // 计算选区在本行的起止，传给 ReaderLoupe 画选区背景。
    int? selStartInLine;
    int? selEndInLine;
    if (line == _selStartLine && line == _selEndLine) {
      // 单行选区
      selStartInLine = _selStartOffset;
      selEndInLine = _selEndOffset;
    } else if (line == _selStartLine) {
      // 起点行（跨行）
      selStartInLine = _selStartOffset;
      selEndInLine = lineText.length;
    } else if (line == _selEndLine) {
      // 终点行（跨行）
      selStartInLine = 0;
      selEndInLine = _selEndOffset;
    }

    const double w = 160;
    const double h = 56;
    const double gap = 18;

    // 放大镜位置也用 Stack 局部坐标，避免 SafeArea 偏差。
    final stackBox =
        _stackKey.currentContext?.findRenderObject() as RenderBox?;
    if (stackBox == null) return const SizedBox.shrink();
    final localFinger = stackBox.globalToLocal(fingerPos);
    final stackSize = stackBox.size;

    final above = Offset(localFinger.dx, localFinger.dy - gap - h / 2);
    var center = above;
    if (above.dy - h / 2 < 8) {
      center = Offset(localFinger.dx, localFinger.dy + gap + h / 2);
    }
    center = Offset(
      center.dx.clamp(w / 2 + 8, stackSize.width - w / 2 - 8),
      center.dy.clamp(h / 2 + 8, stackSize.height - h / 2 - 8),
    );

    final baseStyle = TextStyle(
      fontSize: s.fontSize,
      fontWeight: _toFontWeight(s.fontWeight),
      height: 1.1,
    );

    return Positioned(
      left: center.dx - w / 2,
      top: center.dy - h / 2,
      child: IgnorePointer(
        child: Material(
          elevation: 6,
          borderRadius: BorderRadius.circular(4),
          child: ReaderLoupe(
            lineText: lineText,
            caretOffset: offset,
            style: baseStyle,
            bgColor: Color(s.bgColor),
            fgColor: const Color(0xFF222222),
            caretColor: Theme.of(context).colorScheme.primary,
            // 传选区，放大镜里画上蓝色背景
            selectionStart: selStartInLine,
            selectionEnd: selEndInLine,
            selectionBg: _selectionBg,
            scale: 1.4,
            width: w,
            height: h,
          ),
        ),
      ),
    );
  }

  Widget _buildHBar(BuildContext context, ReaderSettings s) {
    final selected = _selectedText();
    return Positioned(
      left: 8,
      right: 8,
      bottom: 16,
      child: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(10),
        color: Colors.white,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.copy, size: 18),
                    tooltip: '复制',
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      if (selected.isEmpty) return;
                      Clipboard.setData(ClipboardData(text: selected));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('已复制'),
                          duration: Duration(seconds: 1),
                        ),
                      );
                    },
                  ),
                  IconButton(
                    icon: const Icon(Icons.share, size: 18),
                    tooltip: '分享',
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      if (selected.isEmpty) return;
                      Share.share(selected);
                    },
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      selected,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    tooltip: '取消',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => setState(_clearSelection),
                  ),
                ],
              ),
              const Divider(height: 6),
              SizedBox(
                height: 40,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: widget.palettes.length,
                  itemBuilder: (ctx, i) {
                    final p = widget.palettes[i];
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: GestureDetector(
                        onTap: () {
                          if (selected.isEmpty) return;
                          widget.onHighlightAdded(selected, p);
                          setState(_clearSelection);
                        },
                        onLongPress: () {
                          setState(_clearSelection);
                          widget.onPaletteEdit(p.index);
                        },
                        child: Container(
                          width: 36,
                          height: 40,
                          decoration: BoxDecoration(
                            color: p.isGradient ? null : Color(p.colors.first),
                            gradient: p.isGradient
                                ? LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: p.colors
                                        .map((c) => Color(c))
                                        .toList(growable: false),
                                    stops: p.stops.length == p.colors.length
                                        ? p.stops
                                        : null,
                                  )
                                : null,
                            border: Border.all(color: Colors.black12),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            p.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Color(p.textColor),
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ==================== 工具函数 ====================

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

// ==================== 行 Widget ====================

class _ScrollLineRow extends StatelessWidget {
  const _ScrollLineRow({
    required this.lineKey,
    required this.lineIndex,
    required this.text,
    required this.style,
    required this.highlights,
    required this.inSelection,
    required this.isSelStartLine,
    required this.isSelEndLine,
    required this.selStartOffset,
    required this.selEndOffset,
    required this.searchHit,
  });

  /// 挂在最内层 Text.rich 上的 key。
  /// _hitTest 和 _buildHandles 都靠它拿到 RenderParagraph。
  final GlobalKey lineKey;

  final int lineIndex;
  final String text;
  final TextStyle style;
  final List<HighlightEntry> highlights;

  // 选区信息
  final bool inSelection;         // 这一行是否属于选区范围
  final bool isSelStartLine;      // 这一行是选区的起点行
  final bool isSelEndLine;        // 这一行是选区的终点行
  final int selStartOffset;       // 只在 isSelStartLine 时有效，选区在这一行内的起点
  final int selEndOffset;         // 只在 isSelEndLine 时有效，选区在这一行内的终点

  /// 当前搜索命中（如果命中在本行）。start/end 是行内偏移。
  final ({int start, int end})? searchHit;

  static const Color _selectionBg = Color(0x553D7CFF);

  @override
  Widget build(BuildContext context) {
    final spans = _buildSpansWithSelection();

    // 有没有渐变高亮需要垫色块。
    final gradientEntries = <HighlightEntry>[];
    for (final h in highlights) {
      if (h.keyword.isEmpty) continue;
      if (h.colors.length <= 1) continue;
      gradientEntries.add(h);
    }

    if (gradientEntries.isEmpty || text.isEmpty) {
      return Text.rich(
        TextSpan(children: spans),
        style: style,
        softWrap: true,
        key: lineKey,
      );
    }

    return LayoutBuilder(builder: (ctx, constraints) {
      final gradRects = _measureGradientRects(
        text: text,
        style: style,
        maxWidth: constraints.maxWidth,
        entries: gradientEntries,
      );

      return Stack(
        children: [
          for (final g in gradRects)
            Positioned(
              left: g.rect.left,
              top: g.rect.top,
              width: g.rect.width,
              height: g.rect.height,
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: g.colors,
                      stops: g.stops,
                    ),
                  ),
                ),
              ),
            ),
          Text.rich(
            TextSpan(children: spans),
            style: style,
            softWrap: true,
            key: lineKey,
          ),
        ],
      );
    });
  }

  /// 在 `_buildSpans` 基础上再叠加字符级选区染色。
  List<InlineSpan> _buildSpansWithSelection() {
    if (text.isEmpty) return [TextSpan(text: ' ', style: style)];

    // 先得到"用户高亮 + 搜索命中"的上色
    final baseSpans = _buildSpans();

    if (!inSelection) return baseSpans;

    // 计算本行选区范围
    final n = text.length;
    int sFrom;
    int sTo;
    if (isSelStartLine && isSelEndLine) {
      sFrom = selStartOffset.clamp(0, n);
      sTo = selEndOffset.clamp(0, n);
    } else if (isSelStartLine) {
      sFrom = selStartOffset.clamp(0, n);
      sTo = n;
    } else if (isSelEndLine) {
      sFrom = 0;
      sTo = selEndOffset.clamp(0, n);
    } else {
      sFrom = 0;
      sTo = n;
    }
    if (sTo <= sFrom) return baseSpans;

    return _applySelectionToSpans(baseSpans, sFrom, sTo);
  }

  /// 在 spans 上叠加选区染色。sFrom/sTo 是本行内的选区范围。
  List<InlineSpan> _applySelectionToSpans(
    List<InlineSpan> baseSpans,
    int sFrom,
    int sTo,
  ) {
    final out = <InlineSpan>[];
    var cursor = 0;
    for (final span in baseSpans) {
      if (span is! TextSpan) {
        out.add(span);
        continue;
      }
      final t = span.text ?? '';
      if (t.isEmpty) {
        out.add(span);
        continue;
      }
      final spanStart = cursor;
      final spanEnd = cursor + t.length;
      cursor = spanEnd;

      final lo = spanStart > sFrom ? spanStart : sFrom;
      final hi = spanEnd < sTo ? spanEnd : sTo;

      if (lo >= hi) {
        out.add(span);
        continue;
      }

      // 前段（选区外）
      if (lo > spanStart) {
        out.add(TextSpan(
          text: t.substring(0, lo - spanStart),
          style: span.style ?? style,
        ));
      }
      // 中段（选区内）
      out.add(TextSpan(
        text: t.substring(lo - spanStart, hi - spanStart),
        style: (span.style ?? style).copyWith(backgroundColor: _selectionBg),
      ));
      // 后段（选区外）
      if (hi < spanEnd) {
        out.add(TextSpan(
          text: t.substring(hi - spanStart),
          style: span.style ?? style,
        ));
      }
    }
    return out;
  }

  /// 构造"用户高亮 + 当前搜索命中"的 span。搜索命中覆盖用户高亮。
  ///
  /// 渐变高亮（colors.length > 1）不在 span 里设背景色，
  /// 由 build() 的渐变绘制层统一垫色块。
  List<InlineSpan> _buildSpans() {
    if (text.isEmpty) return [TextSpan(text: ' ', style: style)];

    // 1. 用布尔数组标记每个字符的颜色：背景 + 前景
    final n = text.length;
    final bgColors = List<Color?>.filled(n, null);
    final fgColors = List<Color?>.filled(n, null);

    // 2. 普通关键词高亮 + 正则高亮分流
    final regexEntries = <HighlightEntry>[];
    for (final h in highlights) {
      if (h.keyword.isEmpty) continue;
      if (h.isRegex) {
        regexEntries.add(h);
        continue;
      }
      final isGradient = h.colors.length > 1;
      var from = 0;
      while (from <= text.length - h.keyword.length) {
        final idx = text.indexOf(h.keyword, from);
        if (idx < 0) break;
        final end = idx + h.keyword.length;
        for (var j = idx; j < end && j < n; j++) {
          if (!isGradient) {
            bgColors[j] = Color(h.colors.first);
          }
          fgColors[j] = Color(h.textColor);
        }
        from = end;
      }
    }

    // 2.5 正则高亮
    if (regexEntries.isNotEmpty) {
      final regexSpans = matchRegexOnLine(
        lineText: text,
        regexEntries: regexEntries,
      );
      for (final s in regexSpans) {
        final entry = s.entry;
        final isGradient = entry.colors.length > 1;
        final end = s.endInLine < n ? s.endInLine : n;
        for (var j = s.startInLine; j < end; j++) {
          if (!isGradient) {
            bgColors[j] = Color(entry.colors.first);
          }
          fgColors[j] = Color(entry.textColor);
        }
      }
    }

    // 3. 当前搜索命中（覆盖用户高亮）
    if (searchHit != null) {
      final s = searchHit!.start.clamp(0, n);
      final e = searchHit!.end.clamp(0, n);
      for (var j = s; j < e; j++) {
        bgColors[j] = const Color(0xFFFF4081);
        fgColors[j] = const Color(0xFFFFFFFF);
      }
    }

    // 4. 合并连续相同颜色的字符
    final spans = <InlineSpan>[];
    var i = 0;
    while (i < n) {
      final bg = bgColors[i];
      final fg = fgColors[i];
      var j = i + 1;
      while (j < n && bgColors[j] == bg && fgColors[j] == fg) {
        j++;
      }
      final seg = text.substring(i, j);
      if (bg == null && fg == null) {
        spans.add(TextSpan(text: seg, style: style));
      } else {
        spans.add(TextSpan(
          text: seg,
          style: style.copyWith(
            color: fg ?? style.color,
            backgroundColor: bg,
          ),
        ));
      }
      i = j;
    }
    return spans;
  }
}

// ==================== 渐变 rect 测量 ====================

class _GradRect {
  const _GradRect({required this.rect, required this.colors, this.stops});
  final Rect rect;
  final List<Color> colors;
  final List<double>? stops;
}

final Map<String, List<_GradRect>> _gradRectCache = {};
const int _gradRectCacheCap = 256;

/// 测量本行内所有渐变高亮占的字符范围 → 屏幕坐标 rect。
List<_GradRect> _measureGradientRects({
  required String text,
  required TextStyle style,
  required double maxWidth,
  required List<HighlightEntry> entries,
}) {
  if (text.isEmpty || maxWidth <= 0 || entries.isEmpty) return const [];

  final key = '${text.length}:$text\u0000'
      '${style.fontSize}\u0000${style.fontWeight?.index}\u0000'
      '${maxWidth.round()}\u0000'
      '${entries.map((e) => '${e.keyword}:${e.colors.join(",")}').join("|")}';

  final hit = _gradRectCache[key];
  if (hit != null) return hit;

  final tp = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textAlign: TextAlign.left,
    locale: const Locale('zh', 'CN'),
  )..layout(maxWidth: maxWidth);

  final rects = <_GradRect>[];
  for (final h in entries) {
    var from = 0;
    while (from <= text.length - h.keyword.length) {
      final idx = text.indexOf(h.keyword, from);
      if (idx < 0) break;
      final end = idx + h.keyword.length;

      final boxes = tp.getBoxesForSelection(
        TextSelection(baseOffset: idx, extentOffset: end),
      );

      List<double>? stops;
      if (h.stops.length == h.colors.length && h.stops.length > 1) {
        var ok = true;
        for (var i = 1; i < h.stops.length; i++) {
          if (h.stops[i] <= h.stops[i - 1]) {
            ok = false;
            break;
          }
        }
        if (ok) stops = List<double>.from(h.stops);
      }

      final caretAtEnd = tp.getOffsetForCaret(
        TextPosition(offset: end),
        Rect.zero,
      );

      for (var bi = 0; bi < boxes.length; bi++) {
        final box = boxes[bi];
        var right = box.right;
        if (bi == boxes.length - 1 && caretAtEnd.dx < right) {
          right = caretAtEnd.dx;
        }
        rects.add(_GradRect(
          rect: Rect.fromLTRB(box.left, box.top, right, box.bottom),
          colors: h.colors.map((c) => Color(c)).toList(),
          stops: stops,
        ));
      }

      from = end;
    }
  }

  if (_gradRectCache.length >= _gradRectCacheCap) {
    _gradRectCache.clear();
  }
  _gradRectCache[key] = rects;
  return rects;
}

// ==================== 拖动手柄 ====================

class _DragHandle extends StatelessWidget {
  const _DragHandle({
    required this.isLeft,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  final bool isLeft;
  final void Function(Offset globalPos) onDragStart;
  final void Function(Offset globalPos) onDragUpdate;
  final VoidCallback onDragEnd;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (d) => onDragStart(d.globalPosition),
      onPanUpdate: (d) => onDragUpdate(d.globalPosition),
      onPanEnd: (_) => onDragEnd(),
      onPanCancel: onDragEnd,
      child: SizedBox(
        width: 24,
        height: 28,
        child: CustomPaint(
          painter: _HandlePainter(
            color: s.primary.withValues(alpha: 0.75),
            isLeft: isLeft,
          ),
        ),
      ),
    );
  }
}

class _HandlePainter extends CustomPainter {
  _HandlePainter({required this.color, required this.isLeft});

  final Color color;
  final bool isLeft;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final path = Path();
    final w = size.width;
    final h = size.height;
    final mid = h / 2;
    if (isLeft) {
      path.moveTo(w, 0);
      path.lineTo(w, h);
      path.lineTo(0, h);
      path.lineTo(0, mid);
      path.close();
    } else {
      path.moveTo(0, 0);
      path.lineTo(0, h);
      path.lineTo(w, h);
      path.lineTo(w, mid);
      path.close();
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_HandlePainter old) =>
      old.color != color || old.isLeft != isLeft;
}
