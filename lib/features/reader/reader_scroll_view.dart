import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:share_plus/share_plus.dart';

import 'reader_loupe.dart';
import 'reader_models.dart';

/// 滚动模式的阅读视图。
///
/// 交互：
///   · 手指自由上下滑动（GestureDetector 用 translucent，不拦滚动）
///   · 点击（不移动）→ 往下滚一屏
///   · 右滑 → 往上滚一屏
///   · 长按 → 开始选字。此时手势被 GestureDetector 抢走，滚动被锁
///   · 长按后手指滑动 → 扩展选区
///   · 手指停在屏幕上下边缘 → 内容自动滚（边缘自动滚）
///   · 松手 → 显示底部操作栏（复制 / 分享 / 色块条）
///
/// 独立于分页模式。父级 [ReaderScreen] 只需要在两种模式间切换即可。
class ReaderScrollView extends StatefulWidget {
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

  @override
  State<ReaderScrollView> createState() => _ReaderScrollViewState();
}

class _ReaderScrollViewState extends State<ReaderScrollView> {
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

  static const Color _selectionBg = Color(0x773D7CFF);

  @override
  void initState() {
    super.initState();
    _scrollCtrl = ItemScrollController();
    _positions = ItemPositionsListener.create();
    _positions.itemPositions.addListener(_onPositionsChanged);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _jumpToOffset(widget.initialOffset);
    });
  }

  @override
  void dispose() {
    _edgeScrollTimer?.cancel();
    _positions.itemPositions.removeListener(_onPositionsChanged);
    super.dispose();
  }

  // ==================== 进度上报 ====================

  int _lastReportedOffset = -1;

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

  void _jumpToOffset(int charOffset) {
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

  // ==================== 顶部/底部可见行 ====================

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

  // ==================== 手势：点击 / 右滑 ====================

  void _handleTap() {
    if (_hBarVisible || _selStartLine != null) {
      setState(_clearSelection);
      return;
    }
    _scrollDownOneScreen();
  }

  void _handleHorizontalDragEnd(DragEndDetails d) {
    if (_hBarVisible || _selStartLine != null) return;
    final v = d.primaryVelocity ?? 0;
    // 右滑（正速度）→ 往上翻
    if (v > 200) {
      _scrollUpOneScreen();
    } else if (v < -200) {
      _scrollDownOneScreen();
    }
  }

  void _scrollDownOneScreen() {
    if (!_scrollCtrl.isAttached) return;
    final first = _firstVisibleLine();
    final last = _lastVisibleLine();
    if (first == null || last == null) return;
    final visibleCount = last - first + 1;
    final target =
        (first + visibleCount).clamp(0, widget.lines.length - 1);
    _scrollCtrl.jumpTo(index: target);
  }

  void _scrollUpOneScreen() {
    if (!_scrollCtrl.isAttached) return;
    final first = _firstVisibleLine();
    final last = _lastVisibleLine();
    if (first == null || last == null) return;
    final visibleCount = last - first + 1;
    final target =
        (first - visibleCount).clamp(0, widget.lines.length - 1);
    _scrollCtrl.jumpTo(index: target);
  }

  // ==================== 手势：长按选字 ====================

  void _handleLongPressStart(LongPressStartDetails d) {
    final hit = _hitTest(d.globalPosition);
    if (hit == null) return;
    _longPressActive = true;
    _longPressPos = d.globalPosition;
    _loupePos = d.globalPosition;

    setState(() {
      _selStartLine = hit.line;
      _selStartOffset = hit.offset;
      _selEndLine = hit.line;
      _selEndOffset = hit.offset;
      _hBarVisible = false;
    });

    _startEdgeScrollTimer();
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

    // 长按但没有选区（点到了空白）→ 视为普通点击
    if (_selStartLine == null || _selEndLine == null) {
      _handleTap();
      return;
    }

    // 起点终点相同且没有扩展 → 也当作点击
    if (_selStartLine == _selEndLine &&
        _selStartOffset == _selEndOffset) {
      setState(_clearSelection);
      _handleTap();
      return;
    }

    setState(() => _hBarVisible = true);
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

  /// dir = -1 上滚（往顶部），dir = 1 下滚（往底部）。
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

    // 滚完后重算手指位置对应的行/字，更新选区终点。
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

  // ==================== 选区 ====================

  ({int line, int offset})? _hitTest(Offset globalPos) {
    final list = _positions.itemPositions.value;
    // 按 y 从大到小遍历（先命中下半屏，视觉上更符合预期）
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
    _longPressActive = true; // 复用边缘滚检测
    _longPressPos = pos;
    _startEdgeScrollTimer();
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
  }

  // ==================== 渲染 ====================

  @override
  Widget build(BuildContext context) {
    final s = widget.settings;
    final bgColor = Color(s.bgColor);
    final baseStyle = TextStyle(
      fontSize: s.fontSize,
      fontWeight: _toFontWeight(s.fontWeight),
      height: 1.4,
      color: const Color(0xFF222222),
    );

    return ColoredBox(
      color: bgColor,
      child: Stack(
        children: [
          // ---------- 正文 + 手势 ----------
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
                  return _ScrollLineRow(
                    key: key,
                    lineIndex: i,
                    text: widget.lines[i],
                    style: baseStyle,
                    highlights: widget.highlights,
                    inSelection: _isLineInSelection(i),
                  );
                },
              ),
            ),
          ),

          // ---------- 手柄 ----------
          ..._buildHandles(),

          // ---------- 放大镜 ----------
          if (_loupePos != null && _selStartLine != null)
            _buildLoupe(s, _loupePos!),

          // ---------- 底部操作栏 ----------
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

    final widgets = <Widget>[];

    // 起点手柄
    final startCtx = _lineKeys[_selStartLine!]?.currentContext;
    if (startCtx != null) {
      final box = startCtx.findRenderObject() as RenderBox?;
      if (box != null) {
        final topLeft = box.localToGlobal(Offset.zero);
        widgets.add(
          Positioned(
            left: math.max(0, topLeft.dx - 20),
            top: topLeft.dy,
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

    // 终点手柄
    final endCtx = _lineKeys[_selEndLine!]?.currentContext;
    if (endCtx != null) {
      final box = endCtx.findRenderObject() as RenderBox?;
      if (box != null) {
        final topLeft = box.localToGlobal(Offset.zero);
        final size = box.size;
        widgets.add(
          Positioned(
            left: topLeft.dx + size.width,
            top: topLeft.dy + size.height - 28,
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

    const double w = 160;
    const double h = 56;
    const double gap = 18;

    final screenSize = MediaQuery.of(context).size;
    final above = Offset(fingerPos.dx, fingerPos.dy - gap - h / 2);
    var center = above;
    if (above.dy - h / 2 < 8) {
      center = Offset(fingerPos.dx, fingerPos.dy + gap + h / 2);
    }
    center = Offset(
      center.dx.clamp(w / 2 + 8, screenSize.width - w / 2 - 8),
      center.dy.clamp(h / 2 + 8, screenSize.height - h / 2 - 8),
    );

    final baseStyle = TextStyle(
      fontSize: s.fontSize,
      fontWeight: _toFontWeight(s.fontWeight),
      height: 1.4,
    );

    return Positioned(
      left: center.dx - w / 2,
      top: center.dy - h / 2,
      child: IgnorePointer(
        child: Material(
          elevation: 6,
          borderRadius: BorderRadius.circular(4),
          child: ReaderLoupe(
            lineText: widget.lines[line],
            caretOffset: offset,
            style: baseStyle,
            bgColor: Color(s.bgColor),
            fgColor: const Color(0xFF222222),
            caretColor: Theme.of(context).colorScheme.primary,
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
              // ---- 色块条 ----
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
    super.key,
    required this.lineIndex,
    required this.text,
    required this.style,
    required this.highlights,
    required this.inSelection,
  });

  final int lineIndex;
  final String text;
  final TextStyle style;
  final List<HighlightEntry> highlights;
  final bool inSelection;

  @override
  Widget build(BuildContext context) {
    final spans = _buildSpans();
    final bg = inSelection ? const Color(0x223D7CFF) : null;
    return Container(
      color: bg,
      child: Text.rich(
        TextSpan(children: spans),
        style: style,
        softWrap: true,
      ),
    );
  }

  List<InlineSpan> _buildSpans() {
    if (text.isEmpty) return [TextSpan(text: ' ', style: style)];
    if (highlights.isEmpty) return [TextSpan(text: text, style: style)];

    final ranges = <({int start, int end, HighlightEntry entry})>[];
    for (final h in highlights) {
      if (h.keyword.isEmpty) continue;
      var from = 0;
      while (from <= text.length - h.keyword.length) {
        final idx = text.indexOf(h.keyword, from);
        if (idx < 0) break;
        ranges.add((start: idx, end: idx + h.keyword.length, entry: h));
        from = idx + h.keyword.length;
      }
    }
    if (ranges.isEmpty) return [TextSpan(text: text, style: style)];

    ranges.sort((a, b) => a.start.compareTo(b.start));
    final kept = <({int start, int end, HighlightEntry entry})>[];
    var lastEnd = -1;
    for (final r in ranges) {
      if (r.start < lastEnd) continue;
      kept.add(r);
      lastEnd = r.end;
    }

    final spans = <InlineSpan>[];
    var cursor = 0;
    for (final r in kept) {
      if (r.start > cursor) {
        spans.add(
            TextSpan(text: text.substring(cursor, r.start), style: style));
      }
      final entry = r.entry;
      final hlText = text.substring(r.start, r.end);
      if (entry.colors.length > 1) {
        spans.add(TextSpan(
          text: hlText,
          style: style.copyWith(color: Color(entry.textColor)),
        ));
      } else {
        spans.add(TextSpan(
          text: hlText,
          style: style.copyWith(
            color: Color(entry.textColor),
            backgroundColor: Color(entry.colors.first),
          ),
        ));
      }
      cursor = r.end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor), style: style));
    }
    return spans;
  }
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
