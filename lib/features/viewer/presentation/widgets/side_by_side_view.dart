import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../diff/domain/diff_entry.dart';
import '../../../diff/domain/diff_operation.dart';
import '../../../diff/domain/diff_result.dart';
import '../providers/diff_viewer_providers.dart';
import 'inline_char_diff.dart';

class SideBySideView extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    final c = watchDiffColors(ref);
    if (syncScroll) return _buildSynced(context, c);
    return _buildIndependent(context, c);
  }

  // ============ 同步滚动：左右共用一行 ============

  Widget _buildSynced(BuildContext context, DiffColors c) {
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
          child: Scrollbar(
            controller: controller,
            thumbVisibility: false,
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
                return out;
              },
            ),
          ),
        ),
      ],
    );
  }

  // ============ 独立滚动：左右两个 ListView ============

  Widget _buildIndependent(BuildContext context, DiffColors c) {
    final meta = _lineMeta(result);
    final s = Theme.of(context).colorScheme;
    final divider = Container(width: 1, color: s.outlineVariant);

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
                      c: c,
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
                      c: c,
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

  Widget _singleSideTile(
    BuildContext context,
    DiffEntry e,
    int line, {
    required bool isLeft,
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
      // replace 在 dmp 里不会单独出现，为完整性保留。
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
      findQuery: findQuery,
      charDiff: null,
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
    DiffColors c,
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
          child: _Cell(
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
        // 右侧空白：普通背景，无文字
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

class _Cell extends StatelessWidget {
  const _Cell({
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
