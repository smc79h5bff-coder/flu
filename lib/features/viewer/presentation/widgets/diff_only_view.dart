import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../diff/domain/diff_entry.dart';
import '../../../diff/domain/diff_operation.dart';
import '../../../diff/domain/diff_result.dart';
import '../providers/diff_viewer_providers.dart';
import 'inline_char_diff.dart';
import 'side_by_side_view.dart' show AlignedRow, computeAlignedRows;

class DiffOnlyView extends ConsumerWidget {
  const DiffOnlyView({
    required this.result,
    this.originalFileName,
    this.modifiedFileName,
    this.controller,
    this.findQuery = '',
    this.rowKeysByEntry,
    this.showLineNumbers = true,
    this.bodyFontSize = 14.0,
    this.gutterFontSize = 11.0,
    this.onLongPressEntry,
    super.key,
  });

  final DiffResult result;
  final String? originalFileName;
  final String? modifiedFileName;
  final ScrollController? controller;
  final String findQuery;
  final Map<int, GlobalKey>? rowKeysByEntry;
  final bool showLineNumbers;
  final double bodyFontSize;
  final double gutterFontSize;

  /// 长按某行时回调，参数是该行关联的 entry 下标（1 个或 2 个）。
  final void Function(List<int> entryIndices)? onLongPressEntry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final c = watchDiffColors(ref);
    final meta = _lineMeta(result);
    final rows = _computeDiffOnlyRows(result.entries);
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
            header(originalFileName, s.error),
            divider,
            header(modifiedFileName, s.primary),
          ],
        ),
        Expanded(
          child: Scrollbar(
            controller: controller,
            thumbVisibility: true,
            child: ListView.builder(
              key: const Key('diff-only-list'),
              controller: controller,
              itemCount: rows.length,
              itemBuilder: (ctx, i) {
                final spec = rows[i];
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
                  );
                  keyOwners = <int>[spec.del!, spec.ins!];
                } else if (spec.del != null) {
                  final ei = spec.del!;
                  row = _alignedRow(ctx, result.entries[ei], meta[ei], c);
                  keyOwners = <int>[ei];
                } else {
                  final ei = spec.ins!;
                  row = _alignedRow(ctx, result.entries[ei], meta[ei], c);
                  keyOwners = <int>[ei];
                }
                Widget out = row;
                for (final k in keyOwners) {
                  final key = rowKeysByEntry?[k];
                  if (key != null) out = KeyedSubtree(key: key, child: out);
                }
                if (onLongPressEntry != null) {
                  out = GestureDetector(
                    onLongPress: () => onLongPressEntry!(keyOwners),
                    behavior: HitTestBehavior.opaque,
                    child: out,
                  );
                }
                return out;
              },
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
          ),
        ),
      ],
    );
  }

  Widget _alignedRow(
      BuildContext context, DiffEntry e, ({int orig, int mod}) m, DiffColors c) {
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
          child: _DiffCell(
            text: leftText,
            line: m.orig,
            symbol: leftSym,
            bg: leftBg,
            fg: leftFg,
            findQuery: findQuery,
            charDiff: leftCharDiff,
            showLineNumbers: showLineNumbers,
            bodyFontSize: bodyFontSize,
            gutterFontSize: gutterFontSize,
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
            charDiff: rightCharDiff,
            showLineNumbers: showLineNumbers,
            bodyFontSize: bodyFontSize,
            gutterFontSize: gutterFontSize,
          ),
        ),
      ],
    );
  }

  List<AlignedRow> _computeDiffOnlyRows(List<DiffEntry> entries) {
    final all = computeAlignedRows(entries);
    final out = <AlignedRow>[];
    for (final r in all) {
      final delOp = r.del == null ? null : entries[r.del!].operation;
      final insOp = r.ins == null ? null : entries[r.ins!].operation;
      final onlyEqual = (delOp == null || delOp == DiffOperation.equal) &&
          (insOp == null || insOp == DiffOperation.equal);
      if (onlyEqual) continue;
      out.add(r);
    }
    return out;
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

class _DiffCell extends StatelessWidget {
  const _DiffCell({
    required this.text,
    required this.line,
    required this.symbol,
    required this.bg,
    required this.fg,
    required this.findQuery,
    this.charDiff,
    this.showLineNumbers = true,
    this.bodyFontSize = 14.0,
    this.gutterFontSize = 11.0,
  });

  final String text;
  final int line;
  final String symbol;
  final Color bg;
  final Color fg;
  final String findQuery;
  final _CharDiff? charDiff;
  final bool showLineNumbers;
  final double bodyFontSize;
  final double gutterFontSize;

  @override
  Widget build(BuildContext context) {
    final body = Theme.of(context)
        .textTheme
        .bodyMedium
        ?.copyWith(fontSize: bodyFontSize, color: fg);
    final outline = Theme.of(context).colorScheme.outline;

    Widget content;
    if (charDiff != null) {
      content = InlineCharDiff(
        before: charDiff!.before,
        after: charDiff!.after,
        side: charDiff!.side,
        style: body,
        findQuery: findQuery,
        addedFg: charDiff!.addedFg,
        addedBg: charDiff!.addedBg,
        removedFg: charDiff!.removedFg,
        removedBg: charDiff!.removedBg,
      );
    } else if (findQuery.isEmpty || !text.contains(findQuery)) {
      content = Text(text.isEmpty ? ' ' : text, style: body, softWrap: true);
    } else {
      content = RichText(text: TextSpan(style: body, children: _spans(text)));
    }

    return Container(
      color: bg,
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
              Text(symbol,
                  style: TextStyle(
                      color: fg,
                      fontWeight: FontWeight.bold,
                      fontSize: bodyFontSize)),
            ],
          ],
          const SizedBox(width: 6),
          Expanded(child: content),
        ],
      ),
    );
  }

  List<InlineSpan> _spans(String text) {
    final q = findQuery;
    final spans = <InlineSpan>[];
    var start = 0;
    int idx;
    while ((idx = text.indexOf(q, start)) != -1) {
      if (idx > start) spans.add(TextSpan(text: text.substring(start, idx)));
      spans.add(TextSpan(
        text: q,
        style: const TextStyle(
          backgroundColor: Color(0xFFFFF59D),
          fontWeight: FontWeight.bold,
        ),
      ));
      start = idx + q.length;
    }
    if (start < text.length) spans.add(TextSpan(text: text.substring(start)));
    return spans;
  }
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

class _PaneHeader extends StatelessWidget {
  const _PaneHeader({required this.fileName, required this.color});

  final String fileName;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: color.withOpacity(0.08),
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
