import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../diff/domain/diff_entry.dart';
import '../../../diff/domain/diff_operation.dart';
import '../../../diff/domain/diff_result.dart';
import '../providers/diff_viewer_providers.dart';
import 'inline_char_diff.dart';
import '../line_height_calculator.dart';

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
    this.onLongPressEntry,
    super.key,
  });

  final DiffResult result;

  /// 同步滚动模式：每一行取左右栏较高值的高度表。
  final LineHeightTable syncHeightTable;

  /// 独立滚动模式：左栏高度表。
  final LineHeightTable leftHeightTable;

  /// 独立滚动模式：右栏高度表。
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
  final void Function(List<int> entryIndices)? onLongPressEntry;

  static const Color _matchYellow = Color(0xFFFFF59D);
  static const Color _matchPink = Color(0xFFFF4081);

  @override
  ConsumerState<SideBySideView> createState() => _SideBySideViewState();
}

class _SideBySideViewState extends ConsumerState<SideBySideView> {
  final ScrollController _leftCtrl = ScrollController();
  final ScrollController _rightCtrl = ScrollController();

  @override
  void dispose() {
    _leftCtrl.dispose();
    _rightCtrl.dispose();
    super.dispose();
  }

  Widget _scrollbarTheme({required Widget child}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ScrollbarTheme(
      data: ScrollbarThemeData(
        thumbColor: WidgetStatePropertyAll(
          (isDark ? Colors.white : Colors.black).withValues(alpha: 0.42),
        ),
        thickness: const WidgetStatePropertyAll(12),
        radius: const Radius.circular(6),
        trackVisibility: const WidgetStatePropertyAll(false),
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = watchDiffColors(ref);
    if (widget.syncScroll) return _buildSynced(context, c);
    return _buildIndependent(context, c);
  }

  // ============ 同步滚动 ============

  Widget _buildSynced(BuildContext context, DiffColors c) {
    final meta = cachedLineMeta(widget.result);
    final rows = cachedAlignedRows(widget.result);
    final table = widget.syncHeightTable;
    final s = Theme.of(context).colorScheme;
    final divider = Container(width: 1, color: s.outlineVariant);

    Widget header(String? name, Color color) {
      return Expanded(
        child: name == null
            ? const SizedBox.shrink()
            : _PaneHeader(fileName: name, color: color),
      );
    }

    return Column(
      children: [
        Row(
          children: [
            header(widget.originalFileName, s.error),
            divider,
            header(widget.modifiedFileName, s.primary),
          ],
        ),
        Expanded(
          child: _scrollbarTheme(
            child: Scrollbar(
              controller: widget.controller,
              interactive: true,
              child: ListView.builder(
                key: const Key('side-by-side-list'),
                controller: widget.controller,
                addAutomaticKeepAlives: false,
                addRepaintBoundaries: false,
                cacheExtent: 100,
                itemCount: rows.length,
                itemExtentBuilder: (index, dimensions) =>
                    table.heightOf(index),
                itemBuilder: (ctx, i) {
                  final spec = rows[i];
                  final isCurrent = widget.currentMatchEntry != null &&
                      (spec.del == widget.currentMatchEntry ||
                          spec.ins == widget.currentMatchEntry);
                  final Widget row;
                  final List<int> keyOwners;
                  if (spec.del != null && spec.ins != null) {
                    row = _comboRow(
                      context,
                      widget.result.entries[spec.del!],
                      widget.result.entries[spec.ins!],
                      meta[spec.del!],
                      meta[spec.ins!],
                      c,
                      isCurrent,
                    );
                    keyOwners = <int>[spec.del!, spec.ins!];
                  } else if (spec.del != null) {
                    final ei = spec.del!;
                    row = _alignedRow(ctx, widget.result.entries[ei],
                        meta[ei], c, isCurrent);
                    keyOwners = <int>[ei];
                  } else {
                    final ei = spec.ins!;
                    row = _alignedRow(ctx, widget.result.entries[ei],
                        meta[ei], c, isCurrent);
                    keyOwners = <int>[ei];
                  }
                  final Widget out;
                  if (widget.onLongPressEntry != null) {
                    out = GestureDetector(
                      onLongPress: () => widget.onLongPressEntry!(keyOwners),
                      behavior: HitTestBehavior.opaque,
                      child: row,
                    );
                  } else {
                    out = row;
                  }
                  final key = spec.del != null && spec.ins != null
                      ? ValueKey<String>('${spec.del}-${spec.ins}')
                      : ValueKey<int>(spec.del ?? spec.ins!);
                  return KeyedSubtree(key: key, child: out);
                },
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ============ 独立滚动 ============

  Widget _buildIndependent(BuildContext context, DiffColors c) {
    final meta = cachedLineMeta(widget.result);
    final s = Theme.of(context).colorScheme;
    final divider = Container(width: 1, color: s.outlineVariant);

    final leftIndices = <int>[];
    final rightIndices = <int>[];
    for (var i = 0; i < widget.result.entries.length; i++) {
      final op = widget.result.entries[i].operation;
      if (op != DiffOperation.insert) leftIndices.add(i);
      if (op != DiffOperation.delete) rightIndices.add(i);
    }

    Widget header(String? name, Color color) {
      return name == null
          ? const SizedBox.shrink()
          : _PaneHeader(fileName: name, color: color);
    }

    return Column(
      children: [
        Row(
          children: [
            Expanded(child: header(widget.originalFileName, s.error)),
            divider,
            Expanded(child: header(widget.modifiedFileName, s.primary)),
          ],
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _scrollbarTheme(
                  child: Scrollbar(
                    controller: _leftCtrl,
                    interactive: true,
                    child: ListView.builder(
                      key: const Key('sbs-left-list'),
                      controller: _leftCtrl,
                      addAutomaticKeepAlives: false,
                      addRepaintBoundaries: false,
                      cacheExtent: 100,
                      itemCount: leftIndices.length,
                      itemExtentBuilder: (index, dimensions) =>
                          widget.leftHeightTable.heightOf(index),
                      itemBuilder: (ctx, i) {
                        final ei = leftIndices[i];
                        final isCurrent = widget.currentMatchEntry != null &&
                            ei == widget.currentMatchEntry;
                        final tile = _singleSideTile(
                          context,
                          widget.result.entries[ei],
                          meta[ei].orig,
                          isLeft: true,
                          isCurrentMatch: isCurrent,
                          c: c,
                        );
                        final out = widget.onLongPressEntry == null
                            ? tile
                            : GestureDetector(
                                onLongPress: () =>
                                    widget.onLongPressEntry!(<int>[ei]),
                                behavior: HitTestBehavior.opaque,
                                child: tile,
                              );
                        return KeyedSubtree(
                            key: ValueKey<int>(ei), child: out);
                      },
                    ),
                  ),
                ),
              ),
              divider,
              Expanded(
                child: _scrollbarTheme(
                  child: Scrollbar(
                    controller: _rightCtrl,
                    interactive: true,
                    child: ListView.builder(
                      key: const Key('sbs-right-list'),
                      controller: _rightCtrl,
                      addAutomaticKeepAlives: false,
                      addRepaintBoundaries: false,
                      cacheExtent: 100,
                      itemCount: rightIndices.length,
                      itemExtentBuilder: (index, dimensions) =>
                          widget.rightHeightTable.heightOf(index),
                      itemBuilder: (ctx, i) {
                        final ei = rightIndices[i];
                        final isCurrent = widget.currentMatchEntry != null &&
                            ei == widget.currentMatchEntry;
                        final tile = _singleSideTile(
                          context,
                          widget.result.entries[ei],
                          meta[ei].mod,
                          isLeft: false,
                          isCurrentMatch: isCurrent,
                          c: c,
                        );
                        final out = widget.onLongPressEntry == null
                            ? tile
                            : GestureDetector(
                                onLongPress: () =>
                                    widget.onLongPressEntry!(<int>[ei]),
                                behavior: HitTestBehavior.opaque,
                                child: tile,
                              );
                        return KeyedSubtree(
                            key: ValueKey<int>(ei), child: out);
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _singleSideTile(
    BuildContext context,
    DiffEntry e,
    int line, {
    required bool isLeft,
    required bool isCurrentMatch,
    required DiffColors c,
  }) {
    final s = Theme.of(context).colorScheme;
    final plainBg = isLeft ? s.surfaceVariant : s.surface;

    String text;
    String symbol;
    Color bg;
    Color fg;
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
      symbol = '−';
      bg = c.deleteRowBg;
      fg = c.deleteRowFg;
    } else if (e.operation == DiffOperation.insert) {
      text = e.text;
      symbol = '+';
      bg = c.insertRowBg;
      fg = c.insertRowFg;
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
      charDiff: null,
      showLineNumbers: widget.showLineNumbers,
      bodyFontSize: widget.bodyFontSize,
      gutterFontSize: widget.gutterFontSize,
      noWrap: widget.noWrap,
    );
  }

  Widget _comboRow(
    BuildContext context,
    DiffEntry del,
    DiffEntry ins,
    ({int orig, int mod}) delMeta,
    ({int orig, int mod}) insMeta,
    DiffColors c,
    bool isCurrentMatch,
  ) {
    final s = Theme.of(context).colorScheme;
    final leftText = del.text;
    final rightText = ins.text;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _Cell(
            text: leftText,
            line: delMeta.orig,
            symbol: '~',
            bg: c.replaceLeftBg,
            fg: c.replaceLeftFg,
            findQuery: widget.findQuery,
            isCurrentMatch: isCurrentMatch,
            matchYellow: SideBySideView._matchYellow,
            matchPink: SideBySideView._matchPink,
            charDiff: _CharDiff(
              before: leftText,
              after: rightText,
              side: false,
              removedBg: c.charDeleteBg,
              removedFg: c.charDeleteFg,
              addedBg: c.charInsertBg,
              addedFg: c.charInsertFg,
            ),
            showLineNumbers: widget.showLineNumbers,
            bodyFontSize: widget.bodyFontSize,
            gutterFontSize: widget.gutterFontSize,
            noWrap: widget.noWrap,
          ),
        ),
        Container(width: 1, color: s.outlineVariant),
        Expanded(
          child: _Cell(
            text: rightText,
            line: insMeta.mod,
            symbol: '~',
            bg: c.replaceRightBg,
            fg: c.replaceRightFg,
            findQuery: widget.findQuery,
            isCurrentMatch: isCurrentMatch,
            matchYellow: SideBySideView._matchYellow,
            matchPink: SideBySideView._matchPink,
            charDiff: _CharDiff(
              before: leftText,
              after: rightText,
              side: true,
              removedBg: c.charDeleteBg,
              removedFg: c.charDeleteFg,
              addedBg: c.charInsertBg,
              addedFg: c.charInsertFg,
            ),
            showLineNumbers: widget.showLineNumbers,
            bodyFontSize: widget.bodyFontSize,
            gutterFontSize: widget.gutterFontSize,
            noWrap: widget.noWrap,
          ),
        ),
      ],
    );
  }

  Widget _alignedRow(
    BuildContext context,
    DiffEntry e,
    ({int orig, int mod}) m,
    DiffColors c,
    bool isCurrentMatch,
  ) {
    final s = Theme.of(context).colorScheme;
    final plainLeftBg = s.surfaceVariant;
    final plainRightBg = s.surface;
    final defaultFg = Theme.of(context).textTheme.bodyMedium?.color ??
        (Theme.of(context).brightness == Brightness.dark
            ? Colors.white
            : Colors.black);

    String leftText = '';
    String rightText = '';
    Color leftBg = plainLeftBg;
    Color rightBg = plainRightBg;
    Color leftFg = defaultFg;
    Color rightFg = defaultFg;
    String leftSym = '';
    String rightSym = '';
    _CharDiff? leftCharDiff;
    _CharDiff? rightCharDiff;

    switch (e.operation) {
      case DiffOperation.equal:
        leftText = e.text;
        rightText = e.text;
        break;
      case DiffOperation.delete:
        leftText = e.text;
        leftBg = c.deleteRowBg;
        leftFg = c.deleteRowFg;
        leftSym = '−';
        break;
      case DiffOperation.insert:
        rightText = e.text;
        rightBg = c.insertRowBg;
        rightFg = c.insertRowFg;
        rightSym = '+';
        break;
      case DiffOperation.replace:
        leftText = e.oldText.isEmpty ? e.text : e.oldText;
        rightText = e.newText.isEmpty ? e.text : e.newText;
        leftBg = c.replaceLeftBg;
        leftFg = c.replaceLeftFg;
        rightBg = c.replaceRightBg;
        rightFg = c.replaceRightFg;
        leftSym = '~';
        rightSym = '~';
        leftCharDiff = _CharDiff(
          before: leftText,
          after: rightText,
          side: false,
          removedBg: c.charDeleteBg,
          removedFg: c.charDeleteFg,
          addedBg: c.charInsertBg,
          addedFg: c.charInsertFg,
        );
        rightCharDiff = _CharDiff(
          before: leftText,
          after: rightText,
          side: true,
          removedBg: c.charDeleteBg,
          removedFg: c.charDeleteFg,
          addedBg: c.charInsertBg,
          addedFg: c.charInsertFg,
        );
        break;
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _Cell(
            text: leftText,
            line: m.orig,
            symbol: leftSym,
            bg: leftBg,
            fg: leftFg,
            findQuery: widget.findQuery,
            isCurrentMatch: isCurrentMatch,
            matchYellow: SideBySideView._matchYellow,
            matchPink: SideBySideView._matchPink,
            charDiff: leftCharDiff,
            showLineNumbers: widget.showLineNumbers,
            bodyFontSize: widget.bodyFontSize,
            gutterFontSize: widget.gutterFontSize,
            noWrap: widget.noWrap,
          ),
        ),
        Container(width: 1, color: s.outlineVariant),
        Expanded(
          child: _Cell(
            text: rightText,
            line: m.mod,
            symbol: rightSym,
            bg: rightBg,
            fg: rightFg,
            findQuery: widget.findQuery,
            isCurrentMatch: isCurrentMatch,
            matchYellow: SideBySideView._matchYellow,
            matchPink: SideBySideView._matchPink,
            charDiff: rightCharDiff,
            showLineNumbers: widget.showLineNumbers,
            bodyFontSize: widget.bodyFontSize,
            gutterFontSize: widget.gutterFontSize,
            noWrap: widget.noWrap,
          ),
        ),
      ],
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

// ========== 查找高亮 spans 的 LRU 缓存 ==========

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

// ========== 派生数据缓存 ==========

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

class _PaneHeader extends StatelessWidget {
  const _PaneHeader({required this.fileName, required this.color});

  final String fileName;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: color.withValues(alpha: 0.08),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Text(
        fileName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style:
            TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }
}
