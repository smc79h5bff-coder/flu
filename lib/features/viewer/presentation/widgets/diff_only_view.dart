import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../diff/domain/diff_entry.dart';
import '../../../diff/domain/diff_operation.dart';
import '../../../diff/domain/diff_result.dart';
import '../../../import/presentation/providers/import_providers.dart';
import '../providers/diff_viewer_providers.dart';
import 'inline_char_diff.dart';
import '../line_height_calculator.dart';
import 'side_by_side_view.dart'
    show AlignedRow, cachedAlignedRows, cachedLineMeta;
import '../viewer_widgets.dart';



class DiffOnlyView extends ConsumerStatefulWidget {
  const DiffOnlyView({
    required this.result,
    required this.heightTable,
    this.originalFileName,
    this.modifiedFileName,
    this.controller,
    this.findQuery = '',
    this.currentMatchEntry,
    this.showLineNumbers = true,
    this.bodyFontSize = 14.0,
    this.gutterFontSize = 11.0,
      this.contextFontSize = 10.0,
    this.noWrap = false,
    this.jumpedToEntry,
    this.onLongPressEntry,
    super.key,
  });

  final DiffResult result;
  final LineHeightTable heightTable;
  final String? originalFileName;
  final String? modifiedFileName;
  final ScrollController? controller;
  final String findQuery;
  final int? currentMatchEntry;
  final bool showLineNumbers;
  final double bodyFontSize;
  final double gutterFontSize;
    final double contextFontSize;
  final bool noWrap;
  final int? jumpedToEntry;
  final void Function(List<int> entryIndices)? onLongPressEntry;

  static const Color _matchYellow = Color(0xFFFFF59D);
  static const Color _matchPink = Color(0xFFFF4081);

  @override
  ConsumerState<DiffOnlyView> createState() => _DiffOnlyViewState();
}

class _DiffOnlyViewState extends ConsumerState<DiffOnlyView> {
  late final ScrollController _leftCtrl;
  late final ScrollController _rightCtrl;
  bool _syncing = false;

  DiffResult? _widthsFor;
  double _widthsFontSize = -1;
  bool _widthsNoWrap = false;
  double _leftWidth = 0;
  double _rightWidth = 0;

  @override
  void initState() {
    super.initState();
    _leftCtrl = widget.controller ?? ScrollController();
    _leftCtrl.addListener(_syncLR);
    _rightCtrl = ScrollController();
    _rightCtrl.addListener(_syncRL);
  }

  @override
  void dispose() {
    _leftCtrl.removeListener(_syncLR);
    _rightCtrl.removeListener(_syncRL);
    if (widget.controller == null) {
      _leftCtrl.dispose();
    }
    _rightCtrl.dispose();
    super.dispose();
  }

  void _syncLR() {
    if (_syncing) return;
    if (!_leftCtrl.hasClients || !_rightCtrl.hasClients) return;
    final o = _leftCtrl.offset;
    if ((_rightCtrl.offset - o).abs() < 0.5) return;
    _syncing = true;
    try {
      _rightCtrl.jumpTo(o.clamp(
        _rightCtrl.position.minScrollExtent,
        _rightCtrl.position.maxScrollExtent,
      ));
    } catch (_) {}
    _syncing = false;
  }

  void _syncRL() {
    if (_syncing) return;
    if (!_leftCtrl.hasClients || !_rightCtrl.hasClients) return;
    final o = _rightCtrl.offset;
    if ((_leftCtrl.offset - o).abs() < 0.5) return;
    _syncing = true;
    try {
      _leftCtrl.jumpTo(o.clamp(
        _leftCtrl.position.minScrollExtent,
        _leftCtrl.position.maxScrollExtent,
      ));
    } catch (_) {}
    _syncing = false;
  }

  @override
  Widget build(BuildContext context) {
    final c = watchDiffColors(ref);
    final meta = cachedLineMeta(widget.result);
    final rows = cachedDiffOnlyRows(widget.result);
    final s = Theme.of(context).colorScheme;
    final divider = Container(width: 1, color: s.outlineVariant);

    final mq = MediaQuery.of(context);
    final viewportW = mq.size.width;
    final halfW = (viewportW - 1) / 2;

    double leftWidth = halfW;
    double rightWidth = halfW;
    if (widget.noWrap) {
      _ensureWidths(rows);
      leftWidth = _leftWidth > halfW ? _leftWidth : halfW;
      rightWidth = _rightWidth > halfW ? _rightWidth : halfW;
    }

    Widget header(String? name, Color color, {required bool isOriginal}) {
      return Expanded(
        child: name == null
            ? const SizedBox.shrink()
            : _PaneHeader(
                fileName: name,
                color: color,
                isOriginal: isOriginal,
              ),
      );
    }

    Widget pane({required bool isLeft, required double contentWidth}) {
      final ctrl = isLeft ? _leftCtrl : _rightCtrl;
      final list = ListView.builder(
        key: Key(isLeft ? 'do-left-list' : 'do-right-list'),
        controller: ctrl,
        addAutomaticKeepAlives: false,
        addRepaintBoundaries: false,
        cacheExtent: 100,
        itemCount: rows.length,
        itemExtentBuilder: (index, dimensions) =>
            widget.heightTable.heightOf(index),
        itemBuilder: (ctx, i) {
          final spec = rows[i];
          int? eiOpt = isLeft ? spec.del : spec.ins;
          if (eiOpt == null) {
            // 相同行（equal）只挂在 del 上，右侧要退回到对侧取。
            final fallback = isLeft ? spec.ins : spec.del;
            if (fallback != null &&
                widget.result.entries[fallback].operation ==
                    DiffOperation.equal) {
              eiOpt = fallback;
            }
          }
          if (eiOpt == null) {
            return const SizedBox.expand();
          }
          final int ei = eiOpt;
          final int? otherEi = isLeft ? spec.ins : spec.del;
          final String? otherText = otherEi != null
              ? widget.result.entries[otherEi].text
              : null;
          final e = widget.result.entries[ei];
          final m = meta[ei];
          final isCurrent = widget.currentMatchEntry == ei;
          final tile = _singleSideTile(
            context,
            e,
            isLeft ? m.orig : m.mod,
            isLeft: isLeft,
            isCurrentMatch: isCurrent,
            otherText: otherText,
            c: c,
          );
          final out = widget.onLongPressEntry == null
              ? tile
              : GestureDetector(
                  onLongPress: () => widget.onLongPressEntry!(<int>[ei]),
                  behavior: HitTestBehavior.opaque,
                  child: tile,
                );
          final framed = widget.jumpedToEntry == ei
              ? Container(
                  foregroundDecoration: BoxDecoration(
                    border: Border.all(color: Colors.black, width: 2),
                  ),
                  child: out,
                )
              : out;
          return KeyedSubtree(key: ValueKey<int>(ei), child: framed);
        },
      );

      // 左栏不画滚动条，右栏画一根。
      final Widget scrolled = isLeft
          ? list
          : buildViewerScrollbar(child: list, controller: ctrl);

      if (widget.noWrap) {
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: contentWidth,
            height: double.infinity,
            child: scrolled,
          ),
        );
      }
      return scrolled;
    }

    return Column(
      children: [
        Row(
          children: [
            header(widget.originalFileName, s.error, isOriginal: true),
            divider,
            header(widget.modifiedFileName, s.primary, isOriginal: false),
          ],
        ),
        Expanded(
          child: Row(
            children: [
              Expanded(
                child: pane(isLeft: true, contentWidth: leftWidth),
              ),
              divider,
              Expanded(
                child: pane(isLeft: false, contentWidth: rightWidth),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _ensureWidths(List<AlignedRow> rows) {
    if (identical(_widthsFor, widget.result) &&
        _widthsFontSize == widget.bodyFontSize &&
        _widthsNoWrap == widget.noWrap) {
      return;
    }
    var maxL = 0;
    var maxR = 0;
    for (final spec in rows) {
      if (spec.del != null) {
        final t = _displayFor(widget.result.entries[spec.del!], true);
        final n = t.runes.length;
        if (n > maxL) maxL = n;
      }
      // 右侧：优先用 ins；没有的话，若对侧 del 是相同行，借它来算宽度。
      int? rightEi = spec.ins;
      if (rightEi == null &&
          spec.del != null &&
          widget.result.entries[spec.del!].operation ==
              DiffOperation.equal) {
        rightEi = spec.del;
      }
      if (rightEi != null) {
        final t = _displayFor(widget.result.entries[rightEi], false);
        final n = t.runes.length;
        if (n > maxR) maxR = n;
      }
    }
    final cw = widget.bodyFontSize * 0.9;
    final extra = widget.showLineNumbers ? 56.0 : 24.0;
    _leftWidth = maxL * cw + extra;
    _rightWidth = maxR * cw + extra;
    _widthsFor = widget.result;
    _widthsFontSize = widget.bodyFontSize;
    _widthsNoWrap = widget.noWrap;
  }

  String _displayFor(DiffEntry e, bool isLeft) {
    if (e.operation == DiffOperation.replace) {
      return isLeft
          ? (e.oldText.isEmpty ? e.text : e.oldText)
          : (e.newText.isEmpty ? e.text : e.newText);
    }
    return e.text;
  }

  Widget _singleSideTile(
    BuildContext context,
    DiffEntry e,
    int line, {
    required bool isLeft,
    required bool isCurrentMatch,
    required DiffColors c,
    String? otherText,
  }) {
    final s = Theme.of(context).colorScheme;
    final plainBg = Theme.of(context).brightness == Brightness.dark
        ? s.surface
        : Colors.white;

    String text;
    String symbol;
    Color bg;
    Color fg;
    _CharDiff? charDiff;
    final defaultFg = Theme.of(context).textTheme.bodyMedium?.color ??
        (Theme.of(context).brightness == Brightness.dark
            ? Colors.white
            : Colors.black);

    if (e.operation == DiffOperation.equal) {
      text = e.text;
      symbol = '';
      bg = plainBg;
      fg = defaultFg;
    } else if (e.operation == DiffOperation.delete) {
      text = e.text;
      if (otherText != null) {
        symbol = '~';
        bg = c.replaceLeftBg;
        fg = c.replaceLeftFg;
        charDiff = _CharDiff(
          before: text,
          after: otherText,
          side: false,
          removedBg: c.charDeleteBg,
          removedFg: c.charDeleteFg,
          addedBg: c.charInsertBg,
          addedFg: c.charInsertFg,
        );
      } else {
        symbol = '−';
        bg = c.deleteRowBg;
        fg = c.deleteRowFg;
      }
    } else if (e.operation == DiffOperation.insert) {
      text = e.text;
      if (otherText != null) {
        symbol = '~';
        bg = c.replaceRightBg;
        fg = c.replaceRightFg;
        charDiff = _CharDiff(
          before: otherText,
          after: text,
          side: true,
          removedBg: c.charDeleteBg,
          removedFg: c.charDeleteFg,
          addedBg: c.charInsertBg,
          addedFg: c.charInsertFg,
        );
      } else {
        symbol = '+';
        bg = c.insertRowBg;
        fg = c.insertRowFg;
      }
    } else {
      text = isLeft
          ? (e.oldText.isEmpty ? e.text : e.oldText)
          : (e.newText.isEmpty ? e.text : e.newText);
      symbol = '~';
      bg = isLeft ? c.replaceLeftBg : c.replaceRightBg;
      fg = isLeft ? c.replaceLeftFg : c.replaceRightFg;
    }

    final bool isContext = e.operation == DiffOperation.equal;

    return _DiffCell(
      text: text,
      line: line,
      symbol: symbol,
      bg: bg,
      fg: fg,
      findQuery: widget.findQuery,
      isCurrentMatch: isCurrentMatch,
      matchYellow: DiffOnlyView._matchYellow,
      matchPink: DiffOnlyView._matchPink,
      charDiff: charDiff,
      showLineNumbers: widget.showLineNumbers,
      bodyFontSize: widget.bodyFontSize,
      gutterFontSize: widget.gutterFontSize,
        contextFontSize: widget.contextFontSize,
      noWrap: widget.noWrap,
      isContext: isContext,
    );
  }
}

DiffResult? _lastDiffOnlyRowsFor;
List<AlignedRow>? _lastDiffOnlyRows;

List<AlignedRow> cachedDiffOnlyRows(DiffResult result) {
  if (identical(_lastDiffOnlyRowsFor, result) && _lastDiffOnlyRows != null) {
    return _lastDiffOnlyRows!;
  }
  const contextLines = 2;
  final all = cachedAlignedRows(result);

  final diffRowIndices = <int>[];
  for (var i = 0; i < all.length; i++) {
    final r = all[i];
    final delOp = r.del == null ? null : result.entries[r.del!].operation;
    final insOp = r.ins == null ? null : result.entries[r.ins!].operation;
    final onlyEqual = (delOp == null || delOp == DiffOperation.equal) &&
        (insOp == null || insOp == DiffOperation.equal);
    if (!onlyEqual) diffRowIndices.add(i);
  }

  final keep = <int>{};
  for (final di in diffRowIndices) {
    final lo = di - contextLines;
    final hi = di + contextLines;
    for (var k = lo < 0 ? 0 : lo; k <= hi && k < all.length; k++) {
      keep.add(k);
    }
  }

  final sorted = keep.toList()..sort();
  final out = <AlignedRow>[];
  for (final i in sorted) {
    out.add(all[i]);
  }

  _lastDiffOnlyRows = out;
  _lastDiffOnlyRowsFor = result;
  return out;
}

class _CharDiff {
  const _CharDiff({
    required this.before,
    required this.after,
    required this.side,
    required this.removedBg,
    required this.removedFg,
    required this.addedBg,
    required this.addedFg,
  });

  final String before;
  final String after;
  final bool side;
  final Color removedBg;
  final Color removedFg;
  final Color addedBg;
  final Color addedFg;
}

const int _spansCacheCap = 512;
final Map<String, List<InlineSpan>> _spansCache =
    <String, List<InlineSpan>>{};

List<InlineSpan> _cachedSpans(
  String text,
  String findQuery,
  bool isCurrentMatch,
  Color matchYellow,
  Color matchPink,
) {
  final key = '$text\u0000$findQuery\u0000${isCurrentMatch ? 1 : 0}';
  final hit = _spansCache[key];
  if (hit != null) return hit;

  final spans =
      _buildSpans(text, findQuery, isCurrentMatch, matchYellow, matchPink);
  if (_spansCache.length >= _spansCacheCap) {
    _spansCache.clear();
  }
  _spansCache[key] = spans;
  return spans;
}

List<InlineSpan> _buildSpans(
  String text,
  String findQuery,
  bool isCurrentMatch,
  Color matchYellow,
  Color matchPink,
) {
  final q = findQuery;
  if (q.isEmpty || text.isEmpty) {
    return <InlineSpan>[TextSpan(text: text.isEmpty ? ' ' : text)];
  }
  final bg = isCurrentMatch ? matchPink : matchYellow;
  final spans = <InlineSpan>[];
  var start = 0;
  int idx;
  while ((idx = text.indexOf(q, start)) != -1) {
    if (idx > start) spans.add(TextSpan(text: text.substring(start, idx)));
    spans.add(TextSpan(
      text: q,
      style: TextStyle(backgroundColor: bg, fontWeight: FontWeight.bold),
    ));
    start = idx + q.length;
  }
  if (start < text.length) spans.add(TextSpan(text: text.substring(start)));
  return spans.isEmpty ? <InlineSpan>[TextSpan(text: ' ')] : spans;
}

class _DiffCell extends StatelessWidget {
  const _DiffCell({
    required this.text,
    required this.line,
    required this.symbol,
    required this.bg,
    required this.fg,
    required this.findQuery,
    required this.isCurrentMatch,
    required this.matchYellow,
    required this.matchPink,
    this.charDiff,
    this.showLineNumbers = true,
    this.bodyFontSize = 14.0,
    this.gutterFontSize = 11.0,
      this.contextFontSize = 10.0,
    this.noWrap = false,
    this.isContext = false,
  });

  final String text;
  final int line;
  final String symbol;
  final Color bg;
  final Color fg;
  final String findQuery;
  final bool isCurrentMatch;
  final Color matchYellow;
  final Color matchPink;
  final _CharDiff? charDiff;
  final bool showLineNumbers;
  final double bodyFontSize;
  final double gutterFontSize;
    final double contextFontSize;
  final bool noWrap;

  /// 是否是"相同行（上下文）"。是的话：字号用 kContextFontSize，
  /// 并强制不换行（截断），用来节省纵向空间。
  final bool isContext;

  @override
  Widget build(BuildContext context) {
    final double effectiveFontSize =
    isContext ? contextFontSize : bodyFontSize;
final bool effectiveNoWrap = isContext ? true : noWrap;
    final body = TextStyle(
      fontSize: effectiveFontSize,
      color: fg,
      height: 1.35,
    );
    final outline = Theme.of(context).colorScheme.outline;

    final Widget content;
    if (charDiff != null) {
      content = InlineCharDiff(
        before: charDiff!.before,
        after: charDiff!.after,
        side: charDiff!.side,
        style: body,
        findQuery: findQuery,
        isCurrentMatch: isCurrentMatch,
        addedFg: charDiff!.addedFg,
        addedBg: charDiff!.addedBg,
        removedFg: charDiff!.removedFg,
        removedBg: charDiff!.removedBg,
      );
    } else {
      final spans = _cachedSpans(
          text, findQuery, isCurrentMatch, matchYellow, matchPink);
      if (effectiveNoWrap) {
        content = Text.rich(
          TextSpan(style: body, children: spans),
          softWrap: false,
          overflow: TextOverflow.clip,
          maxLines: 1,
        );
      } else {
        content = Text.rich(TextSpan(style: body, children: spans));
      }
    }

    return ColoredBox(
      color: bg,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 1, vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showLineNumbers) ...[
              SizedBox(
                width: 30,
                child: Text(
                    
    line < 0 ? '' : '${line + 1}',
                  textAlign: TextAlign.end,
                  style: TextStyle(
  fontSize: isContext ? contextFontSize : gutterFontSize,
  color: outline,
),
                ),
              ),
              if (symbol.isNotEmpty) ...[
                const SizedBox(width: 4),
                Text(
                  symbol,
                  style: TextStyle(
                    color: fg,
                    fontWeight: FontWeight.bold,
                    fontSize: effectiveFontSize,
                  ),
                ),
              ],
            ],
            const SizedBox(width: 6),
            Expanded(child: content),
          ],
        ),
      ),
    );
  }
}

class _PaneHeader extends ConsumerWidget {
  const _PaneHeader({
    required this.fileName,
    required this.color,
    required this.isOriginal,
  });

  final String fileName;
  final Color color;
  final bool isOriginal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      onLongPress: () => _showInfo(context, ref),
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: double.infinity,
        color: color.withValues(alpha: 0.08),
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
        child: Text(
          fileName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 8,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ),
    );
  }

  Future<void> _showInfo(BuildContext context, WidgetRef ref) async {
    final path = ref.read(isOriginal
        ? originalFilePathProvider
        : modifiedFilePathProvider);
    final encoding = ref.read(isOriginal
        ? originalEncodingProvider
        : modifiedEncodingProvider);

    String sizeStr = '—';
    String timeStr = '—';
    if (path != null) {
      try {
        final st = await File(path).stat();
        final s = st.size;
        if (s < 1024) {
          sizeStr = '$s B';
        } else if (s < 1024 * 1024) {
          sizeStr = '${(s / 1024).toStringAsFixed(1)} KB';
        } else if (s < 1024 * 1024 * 1024) {
          sizeStr = '${(s / 1024 / 1024).toStringAsFixed(1)} MB';
        } else {
          sizeStr = '${(s / 1024 / 1024 / 1024).toStringAsFixed(2)} GB';
        }
        final t = st.modified;
        String two(int n) => n < 10 ? '0$n' : '$n';
        timeStr = '${t.year}-${two(t.month)}-${two(t.day)} '
            '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
      } catch (_) {}
    }

    if (!context.mounted) return;

    Widget row(String label, String value) => Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: Theme.of(context).textTheme.labelSmall),
              const SizedBox(height: 2),
              SelectableText(value),
            ],
          ),
        );

    await showDialog<void>(
      context: context,
      builder: (c) => AlertDialog(
        insetPadding: const EdgeInsets.all(8),
        title: Text(
          fileName,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              row('路径', path ?? '（没有路径，来自剪贴板或粘贴）'),
              row('大小', sizeStr),
              row('修改时间', timeStr),
              row('编码', encoding),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }
}
