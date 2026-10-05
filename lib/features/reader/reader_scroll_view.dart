import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';
import 'package:share_plus/share_plus.dart';

import 'reader_pagination.dart';
import 'reader_panels.dart';
import 'reader_repository.dart';

import 'reader_loupe.dart';
import 'reader_models.dart';
import 'regex_highlight.dart';
import 'reader_search_provider.dart';

/// 滚动模式的阅读视图（正文层）。
///
/// 手势用 `Listener` + 手动计时器（抄分页模式），不抢 Scrollable 的竖向滚动。
///   · 长按 400ms → 开始选字
///   · 手指明显水平滑动 → 翻页
///   · 竖直滑动 → 交给 Scrollable 自由滚动
///   · 快速点击 → 往下滚一屏
///
/// 滚动锁定：有选区 / 长按中 / 拖手柄时，内容不随手指滚动（见 _ReaderScrollPhysics）。
/// 手柄拖动：抄分页模式，记录手指相对文字左上角的偏移，拖动中反推 handleLogic
/// 并把判定点往文字方向推 lineHeight/3，手感贴字。
/// 手柄贴底：选中屏幕最后一行时，手柄翻到文字上方（flip），避免飘出屏幕。
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
    this.onTapOnShell,
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

  final ValueChanged<bool>? onSelectionActiveChanged;
  /// 点击空白时先问父级："这点到按钮 / 热区了吗？"
  /// 返回 true = 父级处理了，不用翻页。
  /// 返回 false / null = 让滚动模式自己翻页。
  final bool Function(Offset globalPos)? onTapOnShell;

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

  int _draggingHandle = 0;
  Offset? _dragHandlePos;

  /// 拖动开始时记下"手指相对手柄逻辑位置（文字左上角）的偏移"。
  /// 拖动时用 手指位置 - 偏移 反推文字新位置，抄分页模式。
  Offset? _dragHandleOffset;

  final Map<int, GlobalKey> _lineKeys = <int, GlobalKey>{};

  final GlobalKey _stackKey = GlobalKey();

  // ---- 手势状态（抄分页模式）----
  Timer? _longPressTimer;
  Offset _downPos = Offset.zero;
  bool _longPressFired = false;
  bool _movedBeyondThreshold = false;
  bool _pressDown = false;
  bool _horizontalDrag = false;
  int _downMs = 0;
  int _lastTapUpMs = 0;

  static const int _longPressMs = 400;
  static const double _moveThresholdDp = 10.0;
  static const int _tapDebounceMs = 100;
  static const double _hDragMinDx = 60.0;

  // ---- 边缘滚动（已禁用，保留占位）----
  Timer? _edgeScrollTimer;

  // ---- 放大镜 ----
  Offset? _loupePos;

  // ---- 选区操作栏 ----
  bool _hBarVisible = false;

  // ---- 进度上报 ----
  int _lastReportedOffset = -1;

  // ---- 选区激活状态 ----
  bool _lastReportedSelectionActive = false;

  // ---- 滚动锁定：有选区 / 长按中 / 拖手柄时，禁止内容随手指滚动 ----
  late final ScrollPhysics _scrollPhysics = _ReaderScrollPhysics(
    isLocked: () =>
        _selStartLine != null ||
        _longPressFired ||
        _draggingHandle != 0,
  );

  // ---- pointer down 之前是否有选区（用于 tap 时判断要不要翻页） ----
  bool _hadSelectionAtDown = false;

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
    _longPressTimer?.cancel();
    _edgeScrollTimer?.cancel();
    _positions.itemPositions.removeListener(_onPositionsChanged);
    final cb = widget.onSelectionActiveChanged;
    if (cb != null && _lastReportedSelectionActive) {
      Future.microtask(() => cb(false));
    }
    super.dispose();
  }

  // ==================== 公开方法 ====================

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

  void jumpByScreen(int dir) {
    if (!_scrollCtrl.isAttached) return;
    final positions = _positions.itemPositions.value;
    if (positions.isEmpty) return;

    final sorted = positions.toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    if (sorted.isEmpty) return;

    if (dir > 0) {
      int? bottomRow;
      double bottomTrailing = 0;
      for (final p in sorted) {
        if (p.itemLeadingEdge < 1.0) {
          bottomRow = p.index;
          bottomTrailing = p.itemTrailingEdge;
        }
      }
      if (bottomRow == null) return;
      final fullyVisible = bottomTrailing <= 1.0 + 1e-3;
      final target = fullyVisible ? bottomRow + 1 : bottomRow;
      final clamped = target.clamp(0, widget.lines.length - 1);
      _scrollCtrl.jumpTo(index: clamped);
      return;
    }

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

  // ==================== 选区状态通知 ====================

  void _notifySelectionActive() {
    final active = _selStartLine != null || _selEndLine != null;
    if (active != _lastReportedSelectionActive) {
      _lastReportedSelectionActive = active;
      widget.onSelectionActiveChanged?.call(active);
    }
  }

  // ==================== 手势：Listener 版本（抄分页模式）====================

  void _onPointerDown(PointerDownEvent e) {
    _longPressTimer?.cancel();
    _downPos = e.position;
    _downMs = DateTime.now().millisecondsSinceEpoch;
    _longPressFired = false;
    _movedBeyondThreshold = false;
    _horizontalDrag = false;
    _pressDown = true;

    _hadSelectionAtDown = _hBarVisible || _selStartLine != null;
    if (_hadSelectionAtDown) {
      setState(_clearSelection);
    }

    _longPressTimer = Timer(const Duration(milliseconds: _longPressMs), () {
      if (!mounted) return;
      if (!_pressDown) return;
      if (_movedBeyondThreshold) return;
      _longPressFired = true;
      _doLongPressStart(_downPos);
    });
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (!_pressDown) return;

    if (_longPressFired) {
      _doLongPressMove(e.position);
      return;
    }

    final dx = e.position.dx - _downPos.dx;
    final dy = e.position.dy - _downPos.dy;
    final absDx = dx.abs();
    final absDy = dy.abs();

    if (!_movedBeyondThreshold) {
      if (absDx > _moveThresholdDp || absDy > _moveThresholdDp) {
        _movedBeyondThreshold = true;
        _longPressTimer?.cancel();
      }
    }

    if (_draggingHandle == 0 && !_horizontalDrag) {
      if (absDx > 20 && absDx > absDy * 1.5) {
        _horizontalDrag = true;
      }
    }
  }

  void _onPointerUp(PointerUpEvent e) {
    _longPressTimer?.cancel();

    if (_draggingHandle != 0) {
      _doDragEnd();
      _pressDown = false;
      return;
    }

    if (_longPressFired) {
      _doLongPressEnd();
      _pressDown = false;
      return;
    }

    if (_horizontalDrag) {
      final dx = e.position.dx - _downPos.dx;
      final elapsed = DateTime.now().millisecondsSinceEpoch - _downMs;
      if (elapsed < 800) {
        if (dx > _hDragMinDx) {
          jumpByScreen(-1);
        } else if (dx < -_hDragMinDx) {
          jumpByScreen(1);
        }
      }
      _pressDown = false;
      _horizontalDrag = false;
      return;
    }

    if (_movedBeyondThreshold) {
      _pressDown = false;
      return;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    if (_lastTapUpMs != 0 && now - _lastTapUpMs < _tapDebounceMs) {
      _pressDown = false;
      return;
    }
    _lastTapUpMs = now;

    _handleTap();
    _pressDown = false;
  }

  void _onPointerCancel(PointerCancelEvent e) {
    _longPressTimer?.cancel();
    _pressDown = false;
    _horizontalDrag = false;
    _longPressFired = false;
    _movedBeyondThreshold = false;
    if (_draggingHandle != 0) {
      _doDragEnd();
    }
  }

  void _handleTap() {
    if (_hadSelectionAtDown) {
      _hadSelectionAtDown = false;
      return;
    }
    if (_hBarVisible || _selStartLine != null) {
      setState(_clearSelection);
      return;
    }
    final handled = widget.onTapOnShell?.call(_downPos) ?? false;
    if (handled) return;
    jumpByScreen(1);
  }

  // ==================== 长按逻辑 ====================

  void _doLongPressStart(Offset pos) {
    final hit = _hitTest(pos);
    if (hit == null) return;

    final lineText = widget.lines[hit.line];
    final (from, to) = _wordRangeAt(lineText, hit.offset);

    _loupePos = pos;
    setState(() {
      _selStartLine = hit.line;
      _selStartOffset = from;
      _selEndLine = hit.line;
      _selEndOffset = to;
      _hBarVisible = false;
    });
    _notifySelectionActive();
  }

  void _doLongPressMove(Offset pos) {
    _loupePos = pos;
    final hit = _hitTest(pos);
    if (hit != null) {
      setState(() {
        _selEndLine = hit.line;
        _selEndOffset = hit.offset;
      });
    } else {
      setState(() {});
    }
  }

  void _doLongPressEnd() {
    _loupePos = null;

    if (_selStartLine == null || _selEndLine == null) {
      _clearSelection();
      _handleTap();
      return;
    }

    final sL = _selStartLine!;
    final eL = _selEndLine!;
    final sO = _selStartOffset ?? 0;
    final eO = _selEndOffset ?? 0;
    final hasSelection = sL != eL || sO != eO;

    if (!hasSelection) {
      setState(_clearSelection);
      _handleTap();
      return;
    }

    setState(() => _hBarVisible = true);
    _notifySelectionActive();
  }

  (int, int) _wordRangeAt(String line, int offset) {
    if (line.isEmpty) return (0, 0);
    var o = offset.clamp(0, line.length - 1);
    final code = line.codeUnitAt(o);

    if (code >= 0x4E00 && code <= 0x9FFF) {
      return (o, o + 1);
    }

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
    return (o, o + 1);
  }

  // ==================== 选区计算 ====================

  /// 返回归一化后的选区：start 永远是物理位置更早的，end 更晚。
  ({int startLine, int startOffset, int endLine, int endOffset})?
      _normSel() {
    final sL = _selStartLine;
    final sO = _selStartOffset;
    final eL = _selEndLine;
    final eO = _selEndOffset;
    if (sL == null || sO == null || eL == null || eO == null) return null;
    if (sL < eL || (sL == eL && sO <= eO)) {
      return (startLine: sL, startOffset: sO, endLine: eL, endOffset: eO);
    }
    return (startLine: eL, startOffset: eO, endLine: sL, endOffset: sO);
  }

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
    _dragHandleOffset = null;
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

  void _handleDragStartInternal(int which, Offset fingerPos) {
    Offset? handleLogic;
    if (which == 1) {
      handleLogic = _posOfCharLeft(_selStartLine!, _selStartOffset ?? 0);
    } else {
      handleLogic = _posOfCharRight(_selEndLine!, _selEndOffset ?? 0);
    }

    setState(() {
      _draggingHandle = which;
      _dragHandlePos = handleLogic ?? fingerPos;
      _dragHandleOffset = handleLogic == null
          ? Offset.zero
          : fingerPos - handleLogic;
      _loupePos = fingerPos;
      _hBarVisible = false;
    });
    _notifySelectionActive();
  }

  void _doDragUpdate(Offset fingerPos) {
    if (_draggingHandle == 0) return;

    final offset = _dragHandleOffset ?? Offset.zero;
    final handleLogic = fingerPos - offset;
    _dragHandlePos = handleLogic;
    _loupePos = fingerPos;

    final fontSize = widget.settings.fontSize;
    final lineHeight = fontSize * 1.1;
    final judge = Offset(
      handleLogic.dx,
      handleLogic.dy + fontSize - lineHeight / 3,
    );

    final hit = _hitTest(judge);
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

  void _doDragEnd() {
    _draggingHandle = 0;
    _dragHandlePos = null;
    _dragHandleOffset = null;
    _loupePos = null;
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
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: _onPointerDown,
              onPointerMove: _onPointerMove,
              onPointerUp: _onPointerUp,
              onPointerCancel: _onPointerCancel,
              child: ScrollablePositionedList.builder(
                itemScrollController: _scrollCtrl,
                itemPositionsListener: _positions,
                physics: _scrollPhysics,
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

                  final norm = _normSel();
                  return _ScrollLineRow(
                    lineKey: key,
                    lineIndex: i,
                    text: widget.lines[i],
                    style: baseStyle,
                    highlights: widget.highlights,
                    inSelection: _isLineInSelection(i),
                    isSelStartLine: norm != null && i == norm.startLine,
                    isSelEndLine: norm != null && i == norm.endLine,
                    selStartOffset: norm?.startOffset ?? 0,
                    selEndOffset: norm?.endOffset ?? 0,
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
    final norm = _normSel();
    if (norm == null) return false;
    return i >= norm.startLine && i <= norm.endLine;
  }

  Offset? _posOfCharLeft(int line, int offset) {
    final key = _lineKeys[line];
    final ctx = key?.currentContext;
    if (ctx == null) return null;
    final rp = ctx.findRenderObject();
    if (rp is! RenderParagraph) return null;

    final lineText = widget.lines[line];
    final off = offset.clamp(0, lineText.length);
    if (lineText.isEmpty) return rp.localToGlobal(Offset.zero);

    if (off >= lineText.length) {
      final boxes = rp.getBoxesForSelection(TextSelection(
        baseOffset: lineText.length - 1,
        extentOffset: lineText.length,
      ));
      if (boxes.isEmpty) return rp.localToGlobal(Offset.zero);
      final box = boxes.last;
      return rp.localToGlobal(Offset(box.left, box.top));
    }

    final boxes = rp.getBoxesForSelection(TextSelection(
      baseOffset: off,
      extentOffset: off + 1,
    ));
    if (boxes.isEmpty) {
      final caret = rp.getOffsetForCaret(
        TextPosition(offset: off),
        Rect.fromLTWH(0, 0, 1, rp.size.height),
      );
      return rp.localToGlobal(caret);
    }
    final box = boxes.first;
    return rp.localToGlobal(Offset(box.left, box.top));
  }

  Offset? _posOfCharRight(int line, int offset) {
    final key = _lineKeys[line];
    final ctx = key?.currentContext;
    if (ctx == null) return null;
    final rp = ctx.findRenderObject();
    if (rp is! RenderParagraph) return null;

    final lineText = widget.lines[line];
    final off = offset.clamp(0, lineText.length);
    if (lineText.isEmpty) return rp.localToGlobal(Offset.zero);

    if (off <= 0) {
      final boxes = rp.getBoxesForSelection(const TextSelection(
        baseOffset: 0,
        extentOffset: 1,
      ));
      if (boxes.isEmpty) return rp.localToGlobal(Offset.zero);
      final box = boxes.first;
      return rp.localToGlobal(Offset(box.left, box.top));
    }

    final boxes = rp.getBoxesForSelection(TextSelection(
      baseOffset: off - 1,
      extentOffset: off,
    ));
    if (boxes.isEmpty) {
      final caret = rp.getOffsetForCaret(
        TextPosition(offset: off),
        Rect.fromLTWH(0, 0, 1, rp.size.height),
      );
      return rp.localToGlobal(caret);
    }
    final box = boxes.last;
    return rp.localToGlobal(Offset(box.right, box.top));
  }

  List<Widget> _buildHandles() {
    if (_selStartLine == null || _selEndLine == null) return const [];
    if (_hBarVisible == false && _draggingHandle == 0 && !_longPressFired) {
      return const [];
    }

    final stackBox =
        _stackKey.currentContext?.findRenderObject() as RenderBox?;
    if (stackBox == null) return const [];

    final norm = _normSel();
    if (norm == null) return const [];

    final widgets = <Widget>[];
    final fontSize = widget.settings.fontSize;
    final stackHeight = stackBox.size.height;

    const trapW = 22.0;
    const trapH = 28.0;

    Widget buildHandle(Offset globalPos, bool isLeft) {
      final local = stackBox.globalToLocal(globalPos);

      final textBottomY = local.dy + fontSize;
      final bottomOverflow = textBottomY + trapH + 4 > stackHeight;
      final double top = bottomOverflow ? local.dy - trapH : textBottomY;

      return Positioned(
        left: isLeft ? math.max(0, local.dx - trapW) : local.dx,
        top: top,
        child: _DragHandle(
          isLeft: isLeft,
          flip: bottomOverflow,
          onDragStart: (pos) => _handleDragStartInternal(isLeft ? 1 : 2, pos),
          onDragUpdate: _doDragUpdate,
          onDragEnd: _doDragEnd,
        ),
      );
    }

    Offset? leftGlobal;
    Offset? rightGlobal;
    if (_draggingHandle == 1 && _dragHandlePos != null) {
      leftGlobal = _dragHandlePos;
      rightGlobal = _posOfCharRight(norm.endLine, norm.endOffset);
    } else if (_draggingHandle == 2 && _dragHandlePos != null) {
      leftGlobal = _posOfCharLeft(norm.startLine, norm.startOffset);
      rightGlobal = _dragHandlePos;
    } else {
      leftGlobal = _posOfCharLeft(norm.startLine, norm.startOffset);
      rightGlobal = _posOfCharRight(norm.endLine, norm.endOffset);
    }

    if (leftGlobal != null) {
      widgets.add(buildHandle(leftGlobal, true));
    }
    if (rightGlobal != null) {
      widgets.add(buildHandle(rightGlobal, false));
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

    int? selStartInLine;
    int? selEndInLine;
    if (line == _selStartLine && line == _selEndLine) {
      selStartInLine = _selStartOffset;
      selEndInLine = _selEndOffset;
    } else if (line == _selStartLine) {
      selStartInLine = _selStartOffset;
      selEndInLine = lineText.length;
    } else if (line == _selEndLine) {
      selStartInLine = 0;
      selEndInLine = _selEndOffset;
    }

    const double w = 160;
    const double h = 56;
    const double gap = 18;

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
    var sLine = _selStartLine;
    var sOff = _selStartOffset;
    var eLine = _selEndLine;
    var eOff = _selEndOffset;
    if (sLine == null || sOff == null || eLine == null || eOff == null) {
      return const SizedBox.shrink();
    }
    if (sLine > eLine || (sLine == eLine && sOff > eOff)) {
      final tl = sLine, to = sOff;
      sLine = eLine;
      sOff = eOff;
      eLine = tl;
      eOff = to;
    }

    final startGlobal = _posOfCharLeft(sLine, sOff);
    final endGlobal = _posOfCharRight(eLine, eOff);
    if (startGlobal == null || endGlobal == null) {
      return const SizedBox.shrink();
    }

    final stackBox =
        _stackKey.currentContext?.findRenderObject() as RenderBox?;
    if (stackBox == null) return const SizedBox.shrink();
    final startPos = stackBox.globalToLocal(startGlobal);
    final endPos = stackBox.globalToLocal(endGlobal);
    final stackSize = stackBox.size;

    const approxW = 260.0;
    const approxH = 150.0;

    final selTop = startPos.dy;
    final selBottom = endPos.dy + s.fontSize;

    final midY = (selTop + selBottom) / 2;
    final screenMid = stackSize.height / 2;
    final showBelow = midY < screenMid;

    double top;
    if (showBelow) {
      top = selBottom + 8;
    } else {
      top = selTop - approxH - 8;
    }
    top = top.clamp(4.0, stackSize.height - approxH - 4);

    double left = startPos.dx - 8;
    if (left + approxW > stackSize.width - 4) {
      left = stackSize.width - approxW - 4;
    }
    if (left < 4) left = 4;

    return Positioned(
      left: left,
      top: top,
      child: Material(
        elevation: 6,
        borderRadius: BorderRadius.circular(10),
        color: Colors.white,
        child: Container(
          width: approxW,
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
                    onPressed: () => setState(_clearSelection),
                  ),
                ],
              ),
              const Divider(height: 6),
              _buildColorRow(0, 10),
              const SizedBox(height: 4),
              _buildColorRow(10, 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildColorRow(int from, int to) {
    final palette = ref.read(readerPaletteProvider);
    final list =
        palette.where((p) => p.index >= from && p.index < to).toList();
    if (list.isEmpty) return const SizedBox.shrink();

    const tileW = 44.0;
    const tileH = 40.0;

    return SizedBox(
      height: tileH,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: list.length,
        itemBuilder: (ctx, i) {
          final p = list[i];
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: GestureDetector(
              onTap: () {
                final word = _selectedText();
                if (word.isEmpty) return;
                widget.onHighlightAdded(word, p);
                setState(_clearSelection);
              },
              onLongPress: () {
                setState(_clearSelection);
                widget.onPaletteEdit(p.index);
              },
              child: Container(
                width: tileW,
                height: tileH,
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

// ==================== 滚动锁定 Physics ====================

/// 滚动模式的自定义 ScrollPhysics。
///
/// [isLocked] 返回 true 时，用户拖拽不产生偏移。
/// 用途：长按选字 / 拖手柄 / 有选区时，禁止内容跟随手指滚动。
class _ReaderScrollPhysics extends ScrollPhysics {
  const _ReaderScrollPhysics({
    required this.isLocked,
    super.parent,
  });

  final bool Function() isLocked;

  @override
  _ReaderScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      _ReaderScrollPhysics(isLocked: isLocked, parent: buildParent(ancestor));

  @override
  double applyPhysicsToUserOffset(ScrollMetrics position, double offset) {
    if (isLocked()) return 0;
    return super.applyPhysicsToUserOffset(position, offset);
  }
}

// ==================== 行 Widget ====================

/// 一条渐变高亮在本行内的起止范围。
typedef _GradSpan = ({int start, int end, HighlightEntry entry});

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

  final GlobalKey lineKey;
  final int lineIndex;
  final String text;
  final TextStyle style;
  final List<HighlightEntry> highlights;

  final bool inSelection;
  final bool isSelStartLine;
  final bool isSelEndLine;
  final int selStartOffset;
  final int selEndOffset;

  final ({int start, int end})? searchHit;

  static const Color _selectionBg = Color(0x553D7CFF);

  @override
  Widget build(BuildContext context) {
    final result = _buildSpansWithSelection();
    final spans = result.spans;
    final gradientSpans = result.gradientSpans;

    // 关键：测量和渲染必须用同一个 locale，否则中英混排时
    // 标点挤压行为不一致，渐变矩形会偏移到旁边的字上。
    final locale = Localizations.maybeLocaleOf(context);

    if (gradientSpans.isEmpty || text.isEmpty) {
      return Text.rich(
        TextSpan(children: spans),
        style: style,
        softWrap: true,
        textAlign: TextAlign.left,
        locale: locale,
        key: lineKey,
      );
    }

    return LayoutBuilder(builder: (ctx, constraints) {
      final gradRects = _measureGradientRectsFromSpans(
        text: text,
        style: style,
        maxWidth: constraints.maxWidth,
        spans: gradientSpans,
        locale: locale,
        builtSpans: spans, // ← 新增：和 Text.rich 用的完全一样的 spans
      );

      return SizedBox(
        width: double.infinity,
        child: Stack(
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
              textAlign: TextAlign.left,
              locale: locale,
              key: lineKey,
            ),
          ],
        ),
      );
    });
  }

  ({List<InlineSpan> spans, List<_GradSpan> gradientSpans})
      _buildSpansWithSelection() {
    if (text.isEmpty) {
      return (
        spans: [TextSpan(text: ' ', style: style)],
        gradientSpans: const <_GradSpan>[],
      );
    }

    final base = _buildSpans();

    if (!inSelection) return base;

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
    if (sTo <= sFrom) return base;

    return (
      spans: _applySelectionToSpans(base.spans, sFrom, sTo),
      gradientSpans: base.gradientSpans,
    );
  }

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

      if (lo > spanStart) {
        out.add(TextSpan(
          text: t.substring(0, lo - spanStart),
          style: span.style ?? style,
        ));
      }
      out.add(TextSpan(
        text: t.substring(lo - spanStart, hi - spanStart),
        style: (span.style ?? style).copyWith(backgroundColor: _selectionBg),
      ));
      if (hi < spanEnd) {
        out.add(TextSpan(
          text: t.substring(hi - spanStart),
          style: span.style ?? style,
        ));
      }
    }
    return out;
  }

  ({List<InlineSpan> spans, List<_GradSpan> gradientSpans}) _buildSpans() {
    if (text.isEmpty) {
      return (
        spans: [TextSpan(text: ' ', style: style)],
        gradientSpans: const <_GradSpan>[],
      );
    }

    final n = text.length;
    final bgColors = List<Color?>.filled(n, null);
    final fgColors = List<Color?>.filled(n, null);
    final gradientSpans = <_GradSpan>[];

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
        if (isGradient) {
          gradientSpans.add((start: idx, end: end, entry: h));
        }
        for (var j = idx; j < end && j < n; j++) {
          if (!isGradient) {
            bgColors[j] = Color(h.colors.first);
          }
          fgColors[j] = Color(h.textColor);
        }
        from = end;
      }
    }

    if (regexEntries.isNotEmpty) {
      final regexSpans = matchRegexOnLine(
        lineText: text,
        regexEntries: regexEntries,
      );
      for (final s in regexSpans) {
        final entry = s.entry;
        final isGradient = entry.colors.length > 1;
        final end = s.endInLine < n ? s.endInLine : n;
        if (isGradient) {
          gradientSpans
              .add((start: s.startInLine, end: end, entry: entry));
        }
        for (var j = s.startInLine; j < end; j++) {
          if (!isGradient) {
            bgColors[j] = Color(entry.colors.first);
          }
          fgColors[j] = Color(entry.textColor);
        }
      }
    }

    if (searchHit != null) {
      final s = searchHit!.start.clamp(0, n);
      final e = searchHit!.end.clamp(0, n);
      for (var j = s; j < e; j++) {
        bgColors[j] = const Color(0xFFFF4081);
        fgColors[j] = const Color(0xFFFFFFFF);
      }
    }

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
    return (spans: spans, gradientSpans: gradientSpans);
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

/// 从"已经算好的字符区间"测量渐变背景矩形。
///
/// spans 由 _ScrollLineRow._buildSpans() 在一次遍历里产出（字面 + 正则），
/// 这里不再做 keyword 匹配 —— 避免正则高亮因 indexOf 找不到位置而不显示渐变。
///
/// [locale] 必须和 Text.rich 渲染时用的 locale 一致，否则中英混排下标点挤压
/// 行为不同，测量出的 boxes 会和实际渲染的字位置差几像素，导致渐变偏到旁边
/// 的字上。
///
/// [builtSpans] 必须和 Text.rich 用的 spans 完全一致。单 span 和多 span 的
/// shaping 断点不同，中文字符位置能差 1~3 像素 —— 用整段单 span 测会偏移。
List<_GradRect> _measureGradientRectsFromSpans({
  required String text,
  required TextStyle style,
  required double maxWidth,
  required List<_GradSpan> spans,
  required Locale? locale,
  required List<InlineSpan> builtSpans,
}) {
  if (text.isEmpty || maxWidth <= 0 || spans.isEmpty) return const [];

  final localeKey = locale?.toString() ?? 'null';
  final key = '${text.length}:$text\u0000'
      '${style.fontSize}\u0000${style.fontWeight?.index}\u0000'
      '${maxWidth.round()}\u0000$localeKey\u0000'
      '${spans.map((s) => '${s.start}:${s.end}:${s.entry.colors.join(",")}').join("|")}';

  final hit = _gradRectCache[key];
  if (hit != null) return hit;

  // ⚠️ 关键：用和 Text.rich 完全相同的 spans 结构。
  // 单 span 和多 span 的 shaping 断点不同，中文字符位置能差 1~3 像素，
  // 导致渐变矩形偏移到旁边的字上。
  final tp = TextPainter(
    text: TextSpan(style: style, children: builtSpans),
    textDirection: TextDirection.ltr,
    textAlign: TextAlign.left,
    locale: locale,
  )..layout(maxWidth: maxWidth);

  final rects = <_GradRect>[];
  for (final s in spans) {
    final hs = s.start.clamp(0, text.length);
    final he = s.end.clamp(0, text.length);
    if (hs >= he) continue;

    final boxes = tp.getBoxesForSelection(
      TextSelection(baseOffset: hs, extentOffset: he),
    );

    List<double>? stops;
    if (s.entry.stops.length == s.entry.colors.length &&
        s.entry.stops.length > 1) {
      var ok = true;
      for (var i = 1; i < s.entry.stops.length; i++) {
        if (s.entry.stops[i] <= s.entry.stops[i - 1]) {
          ok = false;
          break;
        }
      }
      if (ok) stops = List<double>.from(s.entry.stops);
    }

    final caretAtEnd = tp.getOffsetForCaret(
      TextPosition(offset: he),
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
        colors: s.entry.colors.map((c) => Color(c)).toList(),
        stops: stops,
      ));
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
    required this.flip,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  final bool isLeft;

  /// true = 手柄在文字上方（尖角朝下，指向文字）。
  /// false = 手柄在文字下方（尖角朝上，指向文字）。
  final bool flip;

  final void Function(Offset globalPos) onDragStart;
  final void Function(Offset globalPos) onDragUpdate;
  final VoidCallback onDragEnd;

  @override
  Widget build(BuildContext context) {
    final s = Theme.of(context).colorScheme;
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (e) => onDragStart(e.position),
      onPointerMove: (e) => onDragUpdate(e.position),
      onPointerUp: (_) => onDragEnd(),
      onPointerCancel: (_) => onDragEnd(),
      child: SizedBox(
        width: 24,
        height: 28,
        child: CustomPaint(
          painter: _HandlePainter(
            color: s.primary.withValues(alpha: 0.75),
            isLeft: isLeft,
            flip: flip,
          ),
        ),
      ),
    );
  }
}

class _HandlePainter extends CustomPainter {
  _HandlePainter({
    required this.color,
    required this.isLeft,
    required this.flip,
  });

  final Color color;
  final bool isLeft;
  final bool flip;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    final path = Path();
    final w = size.width;
    final h = size.height;
    final mid = h / 2;

    if (!flip) {
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
    } else {
      if (isLeft) {
        path.moveTo(w, h);
        path.lineTo(w, 0);
        path.lineTo(0, 0);
        path.lineTo(0, mid);
        path.close();
      } else {
        path.moveTo(0, h);
        path.lineTo(0, 0);
        path.lineTo(w, 0);
        path.lineTo(w, mid);
        path.close();
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_HandlePainter old) =>
      old.color != color || old.isLeft != isLeft || old.flip != flip;
}
