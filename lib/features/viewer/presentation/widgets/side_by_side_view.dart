import 'package:flutter/material.dart';

import '../../../diff/domain/diff_entry.dart';
import '../../../diff/domain/diff_operation.dart';
import '../../../diff/domain/diff_result.dart';
import 'inline_char_diff.dart';

class SideBySideView extends StatelessWidget {
  const SideBySideView({
    required this.result,
    this.originalFileName,
    this.modifiedFileName,
    this.controller,
    this.findQuery = '',
    this.rowKeysByEntry,
    this.showLineNumbers = true,
    this.bodyFontSize = 14.0,
    this.gutterFontSize = 11.0,
    this.syncScroll = true,
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
  final bool syncScroll;

  @override
  Widget build(BuildContext context) {
    if (syncScroll) return _buildSynced(context);
    return _buildIndependent(context);
  }

  // ============ 同步滚动：左右共用一行 ============

  Widget _buildSynced(BuildContext context) {
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

  // ============ 独立滚动：左右两个 ListView ============

  Widget _buildIndependent(BuildContext context) {
    final meta = _lineMeta(result);
    final s = Theme.of(context).colorScheme;
    final divider = Container(width: 1, color: s.outlineVariant);

    // 左侧只显示非 insert 的 entry；右侧只显示非 delete 的 entry。
    final leftIndices = <int>[];
    final rightIndices = <int>[];
    for (var i = 0; i < result.entries.length; i++) {
      final op = result.entries[i].operation;
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
            Expanded(child: header(originalFileName, s.error)),
            divider,
            Expanded(child: header(modifiedFileName, s.primary)),
          ],
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: ListView.builder(
                  key: const Key('sbs-left-list'),
                  itemCount: leftIndices.length,
                  itemBuilder: (ctx, i) {
                    final ei = leftIndices[i];
                    return _singleSideTile(
                      context,
                      result.entries[ei],
                      meta[ei].orig,
                      isLeft: true,
                    );
                  },
                ),
              ),
              divider,
              Expanded(
                child: ListView.builder(
                  key: const Key('sbs-right-list'),
                  itemCount: rightIndices.length,
                  itemBuilder: (ctx, i) {
                    final ei = rightIndices[i];
                    return _singleSideTile(
                      context,
                      result.entries[ei],
                      meta[ei].mod,
                      isLeft: false,
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 独立滚动模式下的单侧行。只显示 entry 的一侧。
  Widget _singleSideTile(
    BuildContext context,
    DiffEntry e,
    int line, {
    required bool isLeft,
  }) {
    final s = Theme.of(context).colorScheme;
    final String text;
    final String symbol;
    final Color? color;
    if (e.operation == DiffOperation.equal) {
      text = e.text;
      symbol = '';
      color = null;
    } else if (e.operation == DiffOperation.delete) {
      text = e.text;
      symbol = '−';
      color = s.error;
    } else if (e.operation == DiffOperation.insert) {
      text = e.text;
      symbol = '+';
      color = s.error;
    } else {
      // replace
      text = isLeft
          ? (e.oldText.isEmpty ? e.text : e.oldText)
          : (e.newText.isEmpty ? e.text : e.newText);
      symbol = '~';
      color = s.tertiary;
    }
    return _Cell(
      text: text,
      line: line,
      symbol: symbol,
      color: color ?? (isLeft ? s.surfaceVariant : s.surface),
      bg: color == null ? (isLeft ? s.surfaceVariant : s.surface) : null,
      findQuery: findQuery,
      showLineNumbers: showLineNumbers,
      bodyFontSize: bodyFontSize,
      gutterFontSize: gutterFontSize,
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
          child: _Cell(
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
          child: _Cell(
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
      DiffOperation.equal => (e.text, '', null),
      DiffOperation.delete => (e.text, '−', s.error),
      DiffOperation.insert => ('', '', null),
      DiffOperation.replace =>
        (e.oldText.isEmpty ? e.text : e.oldText, '~', s.tertiary),
    };
    final (String rightText, String rightSym, Color? rightColor) =
        switch (e.operation) {
      DiffOperation.equal => (e.text, '', null),
      DiffOperation.insert => (e.text, '+', s.error),
      DiffOperation.delete => ('', '', null),
      DiffOperation.replace =>
        (e.newText.isEmpty ? e.text : e.newText, '~', s.tertiary),
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
            showLineNumbers: showLineNumbers,
            bodyFontSize: bodyFontSize,
            gutterFontSize: gutterFontSize,
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
            showLineNumbers: showLineNumbers,
            bodyFontSize: bodyFontSize,
            gutterFontSize: gutterFontSize,
          ),
        ),
      ],
    );
  }
}

class _CharDiff {
  const _CharDiff(
      {required this.before, required this.after, required this.side});

  final String before;
  final String after;
  final bool side;
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
