import 'package:flutter/material.dart';

import '../../../diff/domain/diff_entry.dart';
import '../../../diff/domain/diff_operation.dart';
import '../../../diff/domain/diff_result.dart';
import 'inline_char_diff.dart';
import 'side_by_side_view.dart' show AlignedRow, computeAlignedRows;

/// Only entries with differences are rendered, laid out side-by-side so the
/// user can see at a glance what was removed (left, original) vs added
/// (right, modified). Each diff entry renders as ONE aligned row (left:
/// delete / replace-old, right: insert / replace-new), so both columns stay
/// vertically in sync — in portrait and landscape alike. PRD §2 Module 6.
class DiffOnlyView extends StatelessWidget {
  const DiffOnlyView({
    required this.result,
    this.originalFileName,
    this.modifiedFileName,
    this.controller,
    this.findQuery = '',
    this.rowKeysByEntry,
    super.key,
  });

  final DiffResult result;
  final String? originalFileName;
  final String? modifiedFileName;
  final ScrollController? controller;
  final String findQuery;
  final Map<int, GlobalKey>? rowKeysByEntry;

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
          ),
        ),
      ],
    );
  }

  Widget _alignedRow(BuildContext context, DiffEntry e, ({int orig, int mod}) m) {
    final s = Theme.of(context).colorScheme;

    final (String leftText, String leftSym, Color? leftColor) =
        switch (e.operation) {
      DiffOperation.delete => (e.text, '−', s.error),
      DiffOperation.insert => ('', '', null),
      DiffOperation.replace => (e.oldText.isEmpty ? e.text : e.oldText, '~', s.tertiary),
      DiffOperation.equal => (e.text, '', null),
    };
    final (String rightText, String rightSym, Color? rightColor) =
        switch (e.operation) {
      DiffOperation.insert => (e.text, '+', s.error),
      DiffOperation.delete => ('', '', null),
      DiffOperation.replace => (e.newText.isEmpty ? e.text : e.newText, '~', s.tertiary),
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
          ),
        ),
      ],
    );
  }

  /// “仅差异”专用：先按块级对齐（复用 side_by_side 的实现），再跳过
  /// 完全不涉及差异的行（即两个 entry 都是 equal 的情况，实际上对齐后
  /// equal 行只会作为单行出现，del/ins 至少一个非 null 才是差异行）。
  ///
  /// 注意：equal 行在对齐结果里是 `(del: i, ins: null)`，其 entry 类型是
  /// equal。所以要按 entry 的 operation 过滤，而不是按 del/ins 是否为 null
  /// 过滤——后者的判据会把 equal 行误留。
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

/// Holds the two texts + which side to render for a character-level diff cell.
class _CharDiff {
  const _CharDiff({required this.before, required this.after, required this.side});

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
  });

  final String text;
  final int line;
  final String symbol;
  final Color? color;
  final String findQuery;
  final Color? bg;
  final _CharDiff? charDiff;

  @override
  Widget build(BuildContext context) {
    final body = Theme.of(context).textTheme.bodyMedium;
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
          SizedBox(
            width: 26,
            child: Text(
              line < 0 ? '' : '$line',
              textAlign: TextAlign.end,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(color: outline),
            ),
          ),
          if (symbol.isNotEmpty) ...[
            const SizedBox(width: 4),
            Text(symbol, style: TextStyle(color: color, fontWeight: FontWeight.bold)),
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
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }
}
