import 'package:flutter/material.dart';

import '../../../diff/domain/diff_entry.dart';
import '../../../diff/domain/diff_operation.dart';
import '../../../diff/domain/diff_result.dart';
import 'inline_char_diff.dart';

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

  /// Optional filenames shown as column headers.
  final String? originalFileName;
  final String? modifiedFileName;

  /// Single scroll controller shared by the aligned rows.
  final ScrollController? controller;

  /// When non-empty, matching substrings inside each line are highlighted.
  final String findQuery;

  /// Optional per-entry [GlobalKey]s used for precise [Scrollable.ensureVisible].
  final Map<int, GlobalKey>? rowKeysByEntry;

  @override
  Widget build(BuildContext context) {
    final meta = _lineMeta(result);
    final rows = _computeRows(result.entries, skipEqual: true);
    final s = Theme.of(context).colorScheme;
    final divider = Container(width: 1, color: s.outlineVariant);

    Widget header(String? name, Color color) {
      return Expanded(
        child: name == null
            ? const SizedBox.shrink()
            : _PaneHeader(fileName: name, color: color, isLeft: true),
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
              if (spec.ins != null) {
                // Merged delete+insert pair row.
                Widget row = _comboRow(context, result.entries[spec.del!],
                    result.entries[spec.ins!], meta[spec.del!], meta[spec.ins!]);
                // 合并行同时挂在 delete 与 insert 两个条目的 key 上：查找命中任
                // 一侧时都能精确 ensureVisible 到这一行。
                final k1 = rowKeysByEntry?[spec.del];
                final k2 = rowKeysByEntry?[spec.ins];
                if (k1 != null) row = KeyedSubtree(key: k1, child: row);
                if (k2 != null) row = KeyedSubtree(key: k2, child: row);
                return row;
              }
              final ei = spec.del!;
              return _withRowKey(_alignedRow(ctx, result.entries[ei], meta[ei]), ei);
            },
          ),
        ),
      ],
    );
  }

  Widget _withRowKey(Widget child, int entryIndex) {
    final key = rowKeysByEntry?[entryIndex];
    return key == null ? child : KeyedSubtree(key: key, child: child);
  }

  /// Merged delete+insert pair row: left shows deleted chars (red + strike),
  /// right shows added chars (green + underline), diffed against each other.
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

    // Char-level diff highlight for replace rows: left shows deleted chars,
    // right shows added chars (both diffed against the other side's text).
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
}

/// Holds the two texts + which side to render for a character-level diff cell.
class _CharDiff {
  const _CharDiff({required this.before, required this.after, required this.side});

  final String before;
  final String after;
  final bool side; // true=right(new), false=left(old)
}

/// One cell inside a diff-only row: gutter + marker + highlighted text.
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

  /// When set, the text is rendered as an inline character-level diff instead
  /// of a plain/text-highlighted node (used for replace rows).
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
      color: bg ?? color?.withOpacity(0.10),
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

/// Computes a lightweight row-spec table (no widgets). Each entry is either
/// `(del: i, ins: null)` = a single-entry row, or `(del: i, ins: i+1)` = a
/// merged delete+insert pair. [skipEqual] drops equal rows (diff-only view).
List<({int? del, int? ins})> _computeRows(List<DiffEntry> entries,
    {bool skipEqual = false}) {
  final rows = <({int? del, int? ins})>[];
  for (var i = 0; i < entries.length; i++) {
    final e = entries[i];
    if (skipEqual && e.operation == DiffOperation.equal) continue;
    final isDel = e.operation == DiffOperation.delete;
    final nextIsIns = i + 1 < entries.length &&
        entries[i + 1].operation == DiffOperation.insert;
    if (isDel && nextIsIns) {
      rows.add((del: i, ins: i + 1));
      i++; // consume the following insert
    } else {
      rows.add((del: i, ins: null));
    }
  }
  return rows;
}

/// Computes the running line number for each side at every entry.
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

/// Slim header strip showing which file the column below represents.
class _PaneHeader extends StatelessWidget {
  const _PaneHeader({
    required this.fileName,
    required this.color,
    required this.isLeft,
  });

  final String fileName;
  final Color color;
  final bool isLeft;

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