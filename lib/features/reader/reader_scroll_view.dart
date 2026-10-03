import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:share_plus/share_plus.dart';

import 'reader_loupe.dart';
import 'reader_models.dart';

/// 滚动模式下的阅读视图。
///
/// 和分页模式的差别：
///   · 内容不切页，一整个连续
///   · 手指自由上下滑动（网页式）
///   · 点击 = 往下滚一屏（无动画）
///   · 右滑 = 往上滚一屏（无动画）
///   · 长按选字，选区冻结滚动（同屏内选择，不做边缘自动滚）
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
    required this.onProgressChanged,
    required this.onHighlightAdded,
  });

  final String text;
  final List<String> lines;
  final List<int> lineStarts;
  final ReaderSettings settings;
  final int initialOffset;
  final List<HighlightEntry> highlights;

  /// 滚动位置变化时回调（字符偏移）。
  final void Function(int charOffset) onProgressChanged;

  /// 用户长按色块加高亮时回调（word + palette）。
  final void Function(String word, HighlightPalette palette) onHighlightAdded;

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

  /// 拖动哪个手柄：0=不在拖，1=左（起点），2=右（终点）。
  int _draggingHandle = 0;
  Offset? _dragHandlePos;

  final Map<int, GlobalKey> _lineKeys = <int, GlobalKey>{};

  // ---- 手势 ----
  Offset _downPos = Offset.zero;
  int _downMs = 0;
  bool _longPressFired = false;
  bool _movedBeyond = false;
  bool _hBarVisible = false;
  Timer? _longPressTimer;
  int _lastTapUpMs = 0;

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
    _longPressTimer?.cancel();
    _positions.itemPositions.removeListener(_onPositionsChanged);
    super.dispose();
  }

  /// 滚动位置变化 → 上报进度。
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

  /// 把字符偏移换算成行索引，然后跳过去。
  void _jumpToOffset(int charOffset) {
    if (!_scrollCtrl.isAttached) return;
    if (widget.lineStarts.isEmpty) return;
    // 二分查找到包含这个偏移的行
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

  // ==================== 手势 ====================

  void _onPointerDown(PointerDownEvent e) {
    _longPressTimer?.cancel();
    _downPos = e.position;
    _downMs = DateTime.now().millisecondsSinceEpoch;
    _longPressFired = false;
    _movedBeyond = false;

    if (_hBarVisible) {
      setState(() => _hBarVisible = false);
    }

    _longPressTimer = Timer(const Duration(milliseconds: 400), () {
      if (!mounted) return;
      if (_movedBeyond) return;
      _longPressFired = true;
      _startSelectionAt(e.position);
    });
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (_draggingHandle != 0) {
      // 手柄拖动
      setState(() => _dragHandlePos = e.position);
      _updateSelectionFromDrag(e.position);
      return;
    }
    if (_longPressFired) {
      // 长按后手指滑动 = 扩展选区
      final hit = _hitTest(e.position);
      if (hit == null) return;
      setState(() {
        _selEndLine = hit.line;
        _selEndOffset = hit.offset;
      });
      return;
    }
    if (!_movedBeyond) {
      final dx = (e.position.dx - _downPos.dx).abs();
      final dy = (e.position.dy - _downPos.dy).abs();
      if (dx > 10 || dy > 10) {
        _movedBeyond = true;
        _longPressTimer?.cancel();
      }
    }
  }

  void _onPointerUp(PointerUpEvent e) {
    _longPressTimer?.cancel();

    if (_draggingHandle != 0) {
      setState(() {
        _draggingHandle = 0;
        _dragHandlePos = null;
        _hBarVisible = true;
      });
      return;
    }

    if (_longPressFired) {
      _longPressFired = false;
      setState(() => _hBarVisible = _selStartLine != null);
      return;
    }

    if (_movedBeyond) return;

    // 点击判定
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastTapUpMs < 100) return;
    _lastTapUpMs = now;

    // 右滑：在 down 到 up 之间 dx > 60 且时间短
    final dx = e.position.dx - _downPos.dx;
    final dt = now - _downMs;
    if (dx > 60 && dt < 800) {
      _scrollUpOneScreen();
      return;
    }
    if (dx < -60 && dt < 800) {
      // 左滑也当作下一屏，可选
      _scrollDownOneScreen();
      return;
    }

    // 普通点击：清选区或翻下一屏
    if (_selStartLine != null || _hBarVisible) {
      setState(() {
        _clearSelection();
      });
      return;
    }
    _scrollDownOneScreen();
  }

  void _onPointerCancel(PointerCancelEvent e) {
    _longPressTimer?.cancel();
    _longPressFired = false;
  }

  void _scrollDownOneScreen() {
    if (!_scrollCtrl.isAttached) return;
    final list = _positions.itemPositions.value;
    if (list.isEmpty) return;
    final first = list.reduce((a, b) => a.index < b.index ? a : b);
    final viewportH = MediaQuery.of(context).size.height;
    final rowH = _estimateRowHeight();
    final rowsPerScreen = math.max(1, (viewportH / rowH).floor());
    final target = (first.index + rowsPerScreen)
        .clamp(0, widget.lines.length - 1);
    _scrollCtrl.jumpTo(index: target);
  }

  void _scrollUpOneScreen() {
    if (!_scrollCtrl.isAttached) return;
    final list = _positions.itemPositions.value;
    if (list.isEmpty) return;
    final first = list.reduce((a, b) => a.index < b.index ? a : b);
    final viewportH = MediaQuery.of(context).size.height;
    final rowH = _estimateRowHeight();
    final rowsPerScreen = math.max(1, (viewportH / rowH).floor());
    final target = (first.index - rowsPerScreen).clamp(0, widget.lines.length - 1);
    _scrollCtrl.jumpTo(index: target);
  }

  double _estimateRowHeight() {
    return widget.settings.fontSize * 1.4 + 12;
  }

  // ==================== 选区 ====================

  ({int line, int offset})? _hitTest(Offset globalPos) {
    // 遍历可见行，找包含这个点的行
    final list = _positions.itemPositions.value;
    for (final p in list) {
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

  void _startSelectionAt(Offset globalPos) {
    final hit = _hitTest(globalPos);
    if (hit == null) return;
    setState(() {
      _selStartLine = hit.line;
      _selStartOffset = hit.offset;
      _selEndLine = hit.line;
      _selEndOffset = hit.offset;
      _hBarVisible = false;
    });
  }

  void _updateSelectionFromDrag(Offset globalPos) {
    final hit = _hitTest(globalPos);
    if (hit == null) return;
    setState(() {
      if (_draggingHandle == 1) {
        _selStartLine = hit.line;
        _selStartOffset = hit.offset;
      } else if (_draggingHandle == 2) {
        _selEndLine = hit.line;
        _selEndOffset = hit.offset;
      }
    });
  }

  void _clearSelection() {
    _selStartLine = null;
    _selStartOffset = null;
    _selEndLine = null;
    _selEndOffset = null;
    _hBarVisible = false;
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
      startL = endL; startO = endO;
      endL = tL; endO = tO;
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
          // ---------- 正文 ----------
          Positioned.fill(
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: _onPointerDown,
              onPointerMove: _onPointerMove,
              onPointerUp: _onPointerUp,
              onPointerCancel: _onPointerCancel,
              child: ScrollablePositionedList.builder(
                itemScrollController: _scrollCtrl,
                itemPositionsListener: _positions,
                itemCount: widget.lines.length,
                padding: EdgeInsets.symmetric(
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
                    isSelStart: i == _selStartLine,
                    isSelEnd: i == _selEndLine,
                  );
                },
              ),
            ),
          ),

          // ---------- 选区覆盖（简化：只画底色，不画精确框） ----------
          // 由于 ScrollablePositionedList 会回收屏幕外的行，
          // 精确的矩形选区比较复杂，这里用行级底色提示。

          // ---------- 手柄 ----------
          ..._buildHandles(),

          // ---------- 放大镜 ----------
          if (_draggingHandle != 0 && _dragHandlePos != null)
            _buildLoupe(s, _dragHandlePos!),

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
    if (_draggingHandle != 0) return const []; // 拖动时不额外显示静态手柄

    final widgets = <Widget>[];
    final startKey = _lineKeys[_selStartLine!];
    final endKey = _lineKeys[_selEndLine!];
    final startCtx = startKey?.currentContext;
    final endCtx = endKey?.currentContext;

    if (startCtx != null) {
      final box = startCtx.findRenderObject() as RenderBox?;
      if (box != null) {
        final topLeft = box.localToGlobal(Offset.zero);
        widgets.add(Positioned(
          left: topLeft.dx - 20,
          top: topLeft.dy,
          child: _DragHandle(
            isLeft: true,
            onDragStart: (pos) {
              setState(() {
                _draggingHandle = 1;
                _dragHandlePos = pos;
                _hBarVisible = false;
              });
            },
          ),
        ));
      }
    }
    if (endCtx != null) {
      final box = endCtx.findRenderObject() as RenderBox?;
      if (box != null) {
        final topLeft = box.localToGlobal(Offset.zero);
        final size = box.size;
        widgets.add(Positioned(
          left: topLeft.dx + size.width,
          top: topLeft.dy + size.height - 28,
          child: _DragHandle(
            isLeft: false,
            onDragStart: (pos) {
              setState(() {
                _draggingHandle = 2;
                _dragHandlePos = pos;
                _hBarVisible = false;
              });
            },
          ),
        ));
      }
    }
    return widgets;
  }

  Widget _buildLoupe(ReaderSettings s, Offset fingerPos) {
    final line = _draggingHandle == 1 ? _selStartLine : _selEndLine;
    final offset = _draggingHandle == 1 ? _selStartOffset : _selEndOffset;
    if (line == null || offset == null) return const SizedBox.shrink();
    if (line < 0 || line >= widget.lines.length) return const SizedBox.shrink();

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
                      final t = _selectedText();
                      if (t.isEmpty) return;
                      Clipboard.setData(ClipboardData(text: t));
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
                      final t = _selectedText();
                      if (t.isEmpty) return;
                      Share.share(t);
                    },
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      _selectedText(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    tooltip: '取消',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => setState(() => _clearSelection()),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

FontWeight _toFontWeight(int v) {
  switch (v) {
    case 100: return FontWeight.w100;
    case 200: return FontWeight.w200;
    case 300: return FontWeight.w300;
    case 400: return FontWeight.w400;
    case 500: return FontWeight.w500;
    case 600: return FontWeight.w600;
    case 700: return FontWeight.w700;
    case 800: return FontWeight.w800;
    case 900: return FontWeight.w900;
    default: return FontWeight.w400;
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
    required this.isSelStart,
    required this.isSelEnd,
  });

  final int lineIndex;
  final String text;
  final TextStyle style;
  final List<HighlightEntry> highlights;
  final bool inSelection;
  final bool isSelStart;
  final bool isSelEnd;

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

    // 找出所有命中区间（关键词字面匹配；正则高亮这里不做）
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
    // 去重叠
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
        spans.add(TextSpan(text: text.substring(cursor, r.start), style: style));
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
  });

  final bool isLeft;
  final void Function(Offset globalPos) onDragStart;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (d) => onDragStart(d.globalPosition),
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
