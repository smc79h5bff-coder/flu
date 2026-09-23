import 'package:flutter/material.dart';

import '../../../diff/domain/diff_entry.dart';
import '../../../diff/domain/diff_operation.dart';
import '../../../diff/domain/diff_result.dart';
import 'inline_char_diff.dart';

/// Side-by-side dual-pane view (PRD §2 Module 6). Each diff entry renders as
/// ONE aligned row with a left cell (original side) and a right cell
/// (modified side), so both columns always stay vertically in sync — in
/// portrait and landscape alike.
///   - equal   : text | text
///   - delete  : old  | (blank)
///   - insert  : (blank) | new
///   - replace : old  | new
/// Left / right scroll together via a single shared [controller].
class SideBySideView extends StatelessWidget {
  const SideBySideView({
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
    // Line number each entry starts at, per side. -1 = not on that side.
    final meta = _lineMeta(result);
    final rows = computeAlignedRows(result.entries);
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
            key: const Key('side-by-side-list'),
            controller: controller,
            itemCount: rows.length,
            itemBuilder: (ctx, i) {
              final spec = rows[i];
              final Widget row;
              final List<int> keyOwners;
              if (spec.del != null && spec.ins != null) {
                // Paired delete+insert row.
                row = _comboRow(
                  context,
                  result.entries[spec.del!],
                  result.entries[spec.ins!],
                  meta[spec.del!],
                  meta[spec.ins!],
                );
                keyOwners = <int>[spec.del!, spec.ins!];
              } else if (spec.del != null) {
                final ei = spec.del!;
                row = _alignedRow(ctx, result.entries[ei], meta[ei]);
                keyOwners = <int>[ei];
              } else {
                // ins-only: single insert row with empty left cell.
                final ei = spec.ins!;
                row = _alignedRow(ctx, result.entries[ei], meta[ei]);
                keyOwners = <int>[ei];
              }
              // 一个渲染行可能挂在多个 entry key 上（配对行同时挂 del/ins），
              // 使查找/差异跳转命中任一侧都能精确定位。
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

  /// Paired delete+insert row: left shows deleted chars (red + strike),
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
          child: _Cell(
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
          child: _Cell(
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

    // Left cell text + marker.
    final (String leftText, String leftSym, Color? leftColor) =
        switch (e.operation) {
      DiffOperation.equal => (e.text, '', null),
      DiffOperation.delete => (e.text, '−', s.error),
      DiffOperation.insert => ('', '', null),
      DiffOperation.replace => (e.oldText.isEmpty ? e.text : e.oldText, '~', s.tertiary),
    };
    // Right cell text + marker.
    final (String rightText, String rightSym, Color? rightColor) =
        switch (e.operation) {
      DiffOperation.equal => (e.text, '', null),
      DiffOperation.insert => (e.text, '+', s.error),
      DiffOperation.delete => ('', '', null),
      DiffOperation.replace => (e.newText.isEmpty ? e.text : e.newText, '~', s.tertiary),
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
          child: _Cell(
            text: leftText,
            line: m.orig,
            symbol: leftSym,
            color: leftColor ?? s.surfaceVariant,
            bg: leftColor == null ? s.surfaceVariant : null,
            findQuery: findQuery,
            charDiff: leftCharDiff,
          ),
        ),
        Container(width: 1, color: s.outlineVariant),
        Expanded(
          child: _Cell(
            text: rightText,
            line: m.mod,
            symbol: rightSym,
            color: rightColor ?? s.surface,
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

class _Cell extends StatelessWidget {
  const _Cell({
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

/// 一个渲染行对应的 entry 索引。至少一个非 null。
/// - del & ins 都非 null：配对行（左 delete / 右 insert）
/// - 只有 del：单独 delete 或 equal / replace 行
/// - 只有 ins：单独 insert 行（左空右内容）
typedef AlignedRow = ({int? del, int? ins});

/// **块级对齐**：把 dmp 输出的“分组”delete/insert 转成“按行号一一配对”的
/// 行表。dmp 输出的 entries 形状是：
///
///     [del del ... del] [ins ins ... ins] [equal] [del del] [ins ins] ...
///
/// 之前 `_computeRows` 只配对“紧邻的 del+ins”，因此一块 N 行的替换只配对
/// 成功 1 对（最后一个 del + 第一个 ins），其余 N-1 对都退化成整行 delete
/// 或整行 insert，行内字符 diff 从不触发 —— 表现就是“问号没标出”“仅差
/// 异视图只显示两处不同”。
///
/// 本函数按块配对：del 块与紧跟的 ins 块按 min(delLen, insLen) 一一配对，
/// 多出来的 delete / insert 各自单独成行。
List<AlignedRow> computeAlignedRows(List<DiffEntry> entries) {
  final rows = <AlignedRow>[];
  var i = 0;
  while (i < entries.length) {
    final e = entries[i];
    if (e.operation == DiffOperation.delete ||
        e.operation == DiffOperation.insert) {
      // 收集连续的 delete
      final delStart = i;
      while (i < entries.length &&
          entries[i].operation == DiffOperation.delete) {
        i++;
      }
      final delEnd = i;
      // 收集紧跟的连续 insert
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
      // equal 或 replace：单行显示
      rows.add((del: i, ins: null));
      i++;
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
