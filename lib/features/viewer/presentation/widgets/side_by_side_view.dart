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
import '../viewer_widgets.dart';

class SideBySideView extends ConsumerStatefulWidget {
  const SideBySideView({
    required this.result,
    required this.syncHeightTable,
    required this.leftHeightTable,
    required this.rightHeightTable,
    this.originalFileName,
    this.modifiedFileName,
    this.controller,
    this.findQuery = '',
    this.currentMatchEntry,
    this.showLineNumbers = true,
    this.bodyFontSize = 14.0,
    this.gutterFontSize = 11.0,
    this.syncScroll = true,
    this.noWrap = false,
    this.jumpedToEntry,
    this.onLongPressEntry,
    super.key,
  });

  final DiffResult result;
  final LineHeightTable syncHeightTable;
  final LineHeightTable leftHeightTable;
  final LineHeightTable rightHeightTable;
  final String? originalFileName;
  final String? modifiedFileName;
  final ScrollController? controller;
  final String findQuery;
  final int? currentMatchEntry;
  final bool showLineNumbers;
  final double bodyFontSize;
  final double gutterFontSize;
  final bool syncScroll;
  final bool noWrap;
  final int? jumpedToEntry;
  final void Function(List<int> entryIndices)? onLongPressEntry;

  static const Color _matchYellow = Color(0xFFFFF59D);
  static const Color _matchPink = Color(0xFFFF4081);

  @override
  ConsumerState<SideBySideView> createState() => _SideBySideViewState();
}

class _SideBySideViewState extends ConsumerState<SideBySideView> {
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
    _leftCtrl.addListener(_syncFromLeft);
    _rightCtrl = ScrollController();
    _rightCtrl.addListener(_syncFromRight);
  }

  @override
  void dispose() {
    _leftCtrl.removeListener(_syncFromLeft);
    _rightCtrl.removeListener(_syncFromRight);
    if (widget.controller == null) {
      _leftCtrl.dispose();
    }
    _rightCtrl.dispose();
    super.dispose();
  }

  void _syncFromLeft() {
    if (_syncing) return;
    if (!_rightCtrl.hasClients || !_leftCtrl.hasClients) return;
    final leftOffset = _leftCtrl.offset;
    if ((_rightCtrl.offset - leftOffset).abs() < 0.5) return;
    _syncing = true;
    try {
      _rightCtrl.jumpTo(leftOffset.clamp(
        _rightCtrl.position.minScrollExtent,
        _rightCtrl.position.maxScrollExtent,
      ));
    } catch (_) {}
    _syncing = false;
  }

  void _syncFromRight() {
    if (_syncing) return;
    if (!_leftCtrl.hasClients || !_rightCtrl.hasClients) return;
    final rightOffset = _rightCtrl.offset;
    if ((_leftCtrl.offset - rightOffset).abs() < 0.5) return;
    _syncing = true;
    try {
      _leftCtrl.jumpTo(rightOffset.clamp(
        _leftCtrl.position.minScrollExtent,
        _leftCtrl.position.maxScrollExtent,
      ));
    } catch (_) {}
    _syncing = false;
  }

  @override
  Widget build(BuildContext context) {
    final c = watchDiffColors(ref);
    return _build(context, c);
  }

  Widget _build(BuildContext context, DiffColors c) {
    final meta = cachedLineMeta(widget.result);
    final rows = cachedAlignedRows(widget.result);
    final table = widget.syncHeightTable;
    final s = Theme.of(context).colorScheme;
    final divider = Container(width: 1, color: s.outlineVariant);

    final mq = MediaQuery.of(context);
    final viewportW = mq.size.width;
    final halfW = (viewportW - 1) / 2;

    double leftWidth = halfW;
    double rightWidth = halfW;
    if (widget.noWrap) {
      _ensureWidths(rows, widget.result);
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

    Widget pane({
      required ScrollController ctrl,
      required bool isLeft,
      required double contentWidth,
    }) {
      final list = ListView.builder(
        controller: ctrl,
        addAutomaticKeepAlives: false,
        addRepaintBoundaries: false,
        cacheExtent: 100,
        itemCount: rows.length,
        itemExtentBuilder: (index, dimensions) => table.heightOf(index),
        itemBuilder: (ctx, i) {
          final spec = rows[i];
          final int? ei = _entryIdxForSpec(spec, isLeft);
          if (ei == null) {
            return const SizedBox.expand();
          }
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
                child: pane(
                  ctrl: _leftCtrl,
                  isLeft: true,
                  contentWidth: leftWidth,
                ),
              ),
              divider,
              Expanded(
                child: pane(
                  ctrl: _rightCtrl,
                  isLeft: false,
                  contentWidth: rightWidth,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  int? _entryIdxForSpec(AlignedRow spec, bool isLeft) {
    final own = isLeft ? spec.del : spec.ins;
    if (own != null) return own;
    final fallback = isLeft ? spec.ins : spec.del;
    if (fallback != null &&
        widget.result.entries[fallback].operation == DiffOperation.equal) {
      return fallback;
    }
    return null;
  }

  void _ensureWidths(List<AlignedRow> rows, DiffResult diff) {
    if (identical(_widthsFor, diff) &&
        _widthsFontSize == widget.bodyFontSize &&
        _widthsNoWrap == widget.noWrap) {
      return;
    }
    var maxL = 0;
    var maxR = 0;
    for (final spec in rows) {
      if (spec.del != null) {
        final t = _displayTextFor(diff.entries[spec.del!], true);
        final n = t.runes.length;
        if (n > maxL) maxL = n;
      }
      if (spec.ins != null) {
        final t = _displayTextFor(diff.entries[spec.ins!], false);
        final n = t.runes.length;
        if (n > maxR) maxR = n;
      }
    }
    final charWidth = widget.bodyFontSize * 0.9;
    final extra = widget.showLineNumbers ? 56.0 : 24.0;
    _leftWidth = maxL * charWidth + extra;
    _rightWidth = maxR * charWidth + extra;
    _widthsFor = diff;
    _widthsFontSize = widget.bodyFontSize;
    _widthsNoWrap = widget.noWrap;
  }

  String _displayTextFor(DiffEntry e, bool isLeft) {
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
    final plainBg =
        Theme.of(context).brightness == Brightness.dark
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

    return _Cell(
      text: text,
      line: line,
      symbol: symbol,
      bg: bg,
      fg: fg,
      findQuery: widget.findQuery,
      isCurrentMatch: isCurrentMatch,
      matchYellow: SideBySideView._matchYellow,
      matchPink: SideBySideView._matchPink,
      charDiff: charDiff,
      showLineNumbers: widget.showLineNumbers,
      bodyFontSize: widget.bodyFontSize,
      gutterFontSize: widget.gutterFontSize,
      noWrap: widget.noWrap,
    );
  }
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

class _Cell extends StatelessWidget {
  const _Cell({
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
    this.noWrap = false,
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
  final bool noWrap;

  @override
  Widget build(BuildContext context) {
    final body = TextStyle(
      fontSize: bodyFontSize,
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
      if (noWrap) {
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
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (showLineNumbers) ...[
              SizedBox(
                width: 30,
                child: Text(
                  line < 0 ? '' : '$line',
                  textAlign: TextAlign.end,
                  style: TextStyle(fontSize: gutterFontSize, color: outline),
                ),
              ),
              if (symbol.isNotEmpty) ...[
                const SizedBox(width: 4),
                Text(
                  symbol,
                  style: TextStyle(
                    color: fg,
                    fontWeight: FontWeight.bold,
                    fontSize: bodyFontSize,
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

typedef AlignedRow = ({int? del, int? ins});

List<AlignedRow> computeAlignedRows(List<DiffEntry> entries) {
  final rows = <AlignedRow>[];
  var i = 0;
  while (i < entries.length) {
    final e = entries[i];
    if (e.operation == DiffOperation.delete ||
        e.operation == DiffOperation.insert) {
      final delStart = i;
      while (i < entries.length &&
          entries[i].operation == DiffOperation.delete) {
        i++;
      }
      final delEnd = i;
      final insStart = i;
      while (i < entries.length &&
          entries[i].operation == DiffOperation.insert) {
        i++;
      }
      final insEnd = i;

      final delCount = delEnd - delStart;
      final insCount = insEnd - insStart;
      final pairs = delCount < insCount ? delCount : insCount;

      for (var k = 0; k < pairs; k++) {
        rows.add((del: delStart + k, ins: insStart + k));
      }
      for (var k = pairs; k < delCount; k++) {
        rows.add((del: delStart + k, ins: null));
      }
      for (var k = pairs; k < insCount; k++) {
        rows.add((del: null, ins: insStart + k));
      }
    } else {
      rows.add((del: i, ins: null));
      i++;
    }
  }
  return rows;
}

List<({int orig, int mod})> _lineMeta(DiffResult result) {
  final meta = <({int orig, int mod})>[];
  var o = 0, m = 0;
  for (final e in result.entries) {
    final usesOrig = e.operation == DiffOperation.equal ||
        e.operation == DiffOperation.delete ||
        e.operation == DiffOperation.replace;
    final usesMod = e.operation == DiffOperation.equal ||
        e.operation == DiffOperation.insert ||
        e.operation == DiffOperation.replace;
    meta.add((orig: usesOrig ? o : -1, mod: usesMod ? m : -1));
    if (usesOrig) o++;
    if (usesMod) m++;
  }
  return meta;
}

DiffResult? _lastAlignedRowsFor;
List<AlignedRow>? _lastAlignedRows;

List<AlignedRow> cachedAlignedRows(DiffResult diff) {
  if (identical(_lastAlignedRowsFor, diff) && _lastAlignedRows != null) {
    return _lastAlignedRows!;
  }
  _lastAlignedRows = computeAlignedRows(diff.entries);
  _lastAlignedRowsFor = diff;
  return _lastAlignedRows!;
}

DiffResult? _lastLineMetaFor;
List<({int orig, int mod})>? _lastLineMeta;

List<({int orig, int mod})> cachedLineMeta(DiffResult diff) {
  if (identical(_lastLineMetaFor, diff) && _lastLineMeta != null) {
    return _lastLineMeta!;
  }
  _lastLineMeta = _lineMeta(diff);
  _lastLineMetaFor = diff;
  return _lastLineMeta!;
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
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Text(
          fileName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
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
