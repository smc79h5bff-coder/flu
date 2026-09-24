import 'package:flutter/material.dart';

import '../../../diff/domain/diff_entry.dart';
import '../../../diff/domain/diff_operation.dart';
import '../../../diff/domain/diff_result.dart';
import 'inline_char_diff.dart';
import 'side_by_side_view.dart' show AlignedRow, computeAlignedRows;

class DiffOnlyView extends StatelessWidget {
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

  @override
  Widget build(BuildContext context) {
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
          child: ListView.builder(
            key: const Key('diff-only-list'),
            controller: controller,
            itemCount: rows.length,
            itemBuilder: (ctx, i) {
              final spec = rows[i];
              final Widget row;
              final List<int> keyOwners;
              if (spec.del != null && spec.ins != null) {
                row = _comboRow(context, result.entries[spec.del!],
                    result.entries[spec.ins!], meta[spec.del!], meta[spec.ins!]);
                keyOwners = <int>[spec.del!, spec.ins!];
              } else if (spec.del != null) {
                final ei = spec.del!;
                row = _alignedRow(ctx, result.entries[ei], meta[ei]);
                keyOwners = <int>[ei];
              } else {
                final ei = spec.ins!;
                row = _alignedRow(ctx, result.entries[ei], meta[ei]);
                keyOwners = <int>[ei];
              }
              Widget out = row;
              for (final k in keyOwners) {
                final key = rowKeysByEntry?[k];
                if (key != null) out = KeyedSubtree(key: key, child: out);
              }
              return out;
            },
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
  ) {
    final s = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _DiffCell(
            text: del.text,
            line: delMeta.orig,
            symbol: '−',
            color: s.error,
            bg: null,
            findQuery: findQuery,
            charDiff: _CharDiff(before: del.text, after: ins.text, side: false),
            showLineNumbers: showLineNumbers,
            bodyFontSize: bodyFontSize,
            gutterFontSize: gutterFontSize,
          ),
        ),
        Container(width: 1, color: s.outlineVariant),
        Expanded(
          child: _DiffCell(
            text: ins.text,
            line: insMeta.mod,
            symbol: '+',
            color: s.error,
            bg: null,
            findQuery: findQuery,
            charDiff: _CharDiff(before: del.text, after: ins.text, side: true),
            showLineNumbers: showLineNumbers,
            bodyFontSize: bodyFontSize,
            gutterFontSize: gutterFontSize,
          ),
        ),
      ],
    );
  }

  Widget _alignedRow(
      BuildContext context, DiffEntry e, ({int orig, int mod}) m) {
    final s = Theme.of(context).colorScheme;

    final (String leftText, String leftSym, Color? leftColor) =
        switch (e.operation) {
      DiffOperation.delete => (e.text, '−', s.error),
      DiffOperation.insert => ('', '', null),
      DiffOperation.replace =>
        (e.oldText.isEmpty ? e.text : e.oldText, '~', s.tertiary),
      DiffOperation.equal => (e.text, '', null),
    };
    final (String rightText, String rightSym, Color? rightColor) =
        switch (e.operation) {
      DiffOperation.insert => (e.text, '+', s.error),
      DiffOperation.delete => ('', '', null),
      DiffOperation.replace =>
        (e.newText.isEmpty ? e.text : e.newText, '~', s.tertiary),
      DiffOperation.equal => (e.text, '', null),
    };

    final _CharDiff? leftCharDiff = e.operation == DiffOperation.replace
        ? _CharDiff(
            before: e.oldText.isEmpty ? e.text : e.oldText,
            after: e.newText.isEmpty ? e.text : e.newText,
            side: false,
          )
        : null;
    final _CharDiff? rightCharDiff = e.operation == DiffOperation.replace
        ? _CharDiff(
            before: e.oldText.isEmpty ? e.text : e.oldText,
            after: e.newText.isEmpty ? e.text : e.newText,
            side: true,
          )
        : null;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _DiffCell(
            text: leftText,
            line: m.orig,
            symbol: leftSym,
            color: leftColor,
            bg: leftColor == null ? s.surfaceVariant : null,
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
            color: rightColor,
            bg: rightColor == null ? s.surface : null,
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
  const _CharDiff(
      {required this.before, required this.after, required this.side});

  final String before;
  final String after;
  final bool side;
}

class _DiffCell extends StatelessWidget {
  const _DiffCell({
    required this.text,
    required this.line,
    required this.symbol,
    required this.color,
    required this.findQuery,
    this.bg,
    this.charDiff,
    this.showLineNumbers = true,
    this.bodyFontSize = 14.0,
    this.gutterFontSize = 11.0,
  });

  final String text;
  final int line;
  final String symbol;
  final Color? color;
  final String findQuery;
  final Color? bg;
  final _CharDiff? charDiff;
  final bool showLineNumbers;
  final double bodyFontSize;
  final double gutterFontSize;

  @override
  Widget build(BuildContext context) {
    final body = Theme.of(context)
        .textTheme
        .bodyMedium
        ?.copyWith(fontSize: bodyFontSize);
    final outline = Theme.of(context).colorScheme.outline;

    Widget content;
    if (charDiff != null) {
      content = InlineCharDiff(
        before: charDiff!.before,
        after: charDiff!.after,
        side: charDiff!.side,
        style: body,
        findQuery: findQuery,
      );
    } else if (findQuery.isEmpty || !text.contains(findQuery)) {
      content = Text(text.isEmpty ? ' ' : text, style: body, softWrap: true);
    } else {
      content = RichText(text: TextSpan(style: body, children: _spans(text)));
    }

    return Container(
      color: bg ?? color?.withOpacity(0.25),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showLineNumbers)
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
                    color: color, fontWeight: FontWeight.bold, fontSize: bodyFontSize)),
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
