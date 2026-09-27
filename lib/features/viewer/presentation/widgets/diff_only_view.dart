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

class DiffOnlyView extends ConsumerWidget {
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
  final bool noWrap;
  final int? jumpedToEntry;
  final void Function(List<int> entryIndices)? onLongPressEntry;

  static const Color _matchYellow = Color(0xFFFFF59D);
  static const Color _matchPink = Color(0xFFFF4081);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = watchDiffColors(ref);
    final meta = cachedLineMeta(result);
    final rows = cachedDiffOnlyRows(result);
    final s = Theme.of(context).colorScheme;
    final divider = Container(width: 1, color: s.outlineVariant);
    final isDark = Theme.of(context).brightness == Brightness.dark;

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

    return Column(
      children: [
        Row(
          children: [
            header(originalFileName, s.error, isOriginal: true),
            divider,
            header(modifiedFileName, s.primary, isOriginal: false),
          ],
        ),
        Expanded(
          child: ScrollbarTheme(
            data: ScrollbarThemeData(
thumbColor: WidgetStatePropertyAll(
  (isDark ? Colors.white : Colors.black).withValues(alpha: 0.22),
),
thickness: const WidgetStatePropertyAll(16),
radius: const Radius.circular(8),
minThumbLength: 40,
              trackVisibility: const WidgetStatePropertyAll(false),
            ),
            child: Scrollbar(
              controller: controller,
              interactive: true,
              child: ListView.builder(
                key: const Key('diff-only-list'),
                controller: controller,
                addAutomaticKeepAlives: false,
                addRepaintBoundaries: false,
                cacheExtent: 100,
                itemCount: rows.length,
                itemExtentBuilder: (index, dimensions) =>
                    heightTable.heightOf(index),
                itemBuilder: (ctx, i) {
                  final spec = rows[i];
                  final isCurrent = currentMatchEntry != null &&
                      (spec.del == currentMatchEntry ||
                          spec.ins == currentMatchEntry);
                  final Widget row;
                  final List<int> keyOwners;
                  if (spec.del != null && spec.ins != null) {
                    row = _comboRow(
                      context,
                      result.entries[spec.del!],
                      result.entries[spec.ins!],
                      meta[spec.del!],
                      meta[spec.ins!],
                      c,
                      isCurrent,
                    );
                    keyOwners = <int>[spec.del!, spec.ins!];
                  } else if (spec.del != null) {
                    final ei = spec.del!;
                    row = _alignedRow(
                        ctx, result.entries[ei], meta[ei], c, isCurrent);
                    keyOwners = <int>[ei];
                  } else {
                    final ei = spec.ins!;
                    row = _alignedRow(
                        ctx, result.entries[ei], meta[ei], c, isCurrent);
                    keyOwners = <int>[ei];
                  }
                  final Widget out;
                  if (onLongPressEntry != null) {
                    out = GestureDetector(
                      onLongPress: () => onLongPressEntry!(keyOwners),
                      behavior: HitTestBehavior.opaque,
                      child: row,
                    );
                  } else {
                    out = row;
                  }
                  final bool isJumped = jumpedToEntry != null &&
                      (spec.del == jumpedToEntry ||
                          spec.ins == jumpedToEntry);
                  final Widget framed = isJumped
                      ? Container(
                          foregroundDecoration: BoxDecoration(
                            border: Border.all(color: Colors.black, width: 2),
                          ),
                          child: out,
                        )
                      : out;
                  final key = spec.del != null && spec.ins != null
                      ? ValueKey<String>('${spec.del}-${spec.ins}')
                      : ValueKey<int>(spec.del ?? spec.ins!);
                  return KeyedSubtree(key: key, child: framed);
                },
              ),
            ),
          ),
        ),
      ],
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
          child: _DiffCell(
            text: leftText,
            line: delMeta.orig,
            symbol: '~',
            bg: c.replaceLeftBg,
            fg: c.replaceLeftFg,
            findQuery: findQuery,
            isCurrentMatch: isCurrentMatch,
            matchYellow: _matchYellow,
            matchPink: _matchPink,
            charDiff: _CharDiff(
              before: leftText,
              after: rightText,
              side: false,
              removedBg: c.charDeleteBg,
              removedFg: c.charDeleteFg,
              addedBg: c.charInsertBg,
              addedFg: c.charInsertFg,
            ),
            showLineNumbers: showLineNumbers,
            bodyFontSize: bodyFontSize,
            gutterFontSize: gutterFontSize,
            noWrap: noWrap,
          ),
        ),
        Container(width: 1, color: s.outlineVariant),
        Expanded(
          child: _DiffCell(
            text: rightText,
            line: insMeta.mod,
            symbol: '~',
            bg: c.replaceRightBg,
            fg: c.replaceRightFg,
            findQuery: findQuery,
            isCurrentMatch: isCurrentMatch,
            matchYellow: _matchYellow,
            matchPink: _matchPink,
            charDiff: _CharDiff(
              before: leftText,
              after: rightText,
              side: true,
              removedBg: c.charDeleteBg,
              removedFg: c.charDeleteFg,
              addedBg: c.charInsertBg,
              addedFg: c.charInsertFg,
            ),
            showLineNumbers: showLineNumbers,
            bodyFontSize: bodyFontSize,
            gutterFontSize: gutterFontSize,
            noWrap: noWrap,
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
final isDark = Theme.of(context).brightness == Brightness.dark;
final plainBg = isDark ? s.surface : Colors.white;
final plainLeftBg = plainBg;
final plainRightBg = plainBg;
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
          child: _DiffCell(
            text: leftText,
            line: m.orig,
            symbol: leftSym,
            bg: leftBg,
            fg: leftFg,
            findQuery: findQuery,
            isCurrentMatch: isCurrentMatch,
            matchYellow: _matchYellow,
            matchPink: _matchPink,
            charDiff: leftCharDiff,
            showLineNumbers: showLineNumbers,
            bodyFontSize: bodyFontSize,
            gutterFontSize: gutterFontSize,
            noWrap: noWrap,
          ),
        ),
        Container(width: 1, color: s.outlineVariant),
        Expanded(
          child: _DiffCell(
            text: rightText,
            line: m.mod,
            symbol: rightSym,
            bg: rightBg,
            fg: rightFg,
            findQuery: findQuery,
            isCurrentMatch: isCurrentMatch,
            matchYellow: _matchYellow,
            matchPink: _matchPink,
            charDiff: rightCharDiff,
            showLineNumbers: showLineNumbers,
            bodyFontSize: bodyFontSize,
            gutterFontSize: gutterFontSize,
            noWrap: noWrap,
          ),
        ),
      ],
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

    final Widget rawContent;
    if (charDiff != null) {
      rawContent = InlineCharDiff(
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
      rawContent = Text.rich(TextSpan(style: body, children: spans));
    }

    final Widget content = noWrap
        ? SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: rawContent,
          )
        : rawContent;

    return ColoredBox(
      color: bg,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
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
