import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../diff/domain/diff_entry.dart';
import '../../../diff/domain/diff_operation.dart';
import '../../../diff/domain/diff_result.dart';
import '../providers/diff_viewer_providers.dart';
import 'inline_char_diff.dart';

class SideBySideView extends ConsumerStatefulWidget {
  const SideBySideView({
    required this.result,
    this.originalFileName,
    this.modifiedFileName,
    this.controller,
    this.findQuery = '',
    this.currentMatchEntry,
    this.rowKeysByEntry,
    this.showLineNumbers = true,
    this.bodyFontSize = 14.0,
    this.gutterFontSize = 11.0,
    this.syncScroll = true,
    this.onLongPressEntry,
    super.key,
  });

  final DiffResult result;
  final String? originalFileName;
  final String? modifiedFileName;
  final ScrollController? controller;
  final String findQuery;
  final int? currentMatchEntry;
  final Map<int, GlobalKey>? rowKeysByEntry;
  final bool showLineNumbers;
  final double bodyFontSize;
  final double gutterFontSize;
  final bool syncScroll;
  final void Function(List<int> entryIndices)? onLongPressEntry;

  static const Color _matchYellow = Color(0xFFFFF59D);
  static const Color _matchOrange = Color(0xFFFF9800);

  @override
  ConsumerState<SideBySideView> createState() => _SideBySideViewState();
}

class _SideBySideViewState extends ConsumerState<SideBySideView> {
  // 独立滚动模式下左右各自需要独立 controller（同步模式仍用 widget.controller）。
  final ScrollController _leftCtrl = ScrollController();
  final ScrollController _rightCtrl = ScrollController();

  @override
  void dispose() {
    _leftCtrl.dispose();
    _rightCtrl.dispose();
    super.dispose();
  }

  /// 统一滚动条样式：粗一点、半透明、闲置隐藏、可拖拽。
  Widget _scrollbar({
    required BuildContext context,
    required ScrollController? controller,
    required Widget child,
  }) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final thumb =
        (isDark ? Colors.white : Colors.black).withOpacity(0.42);
    return Scrollbar(
      controller: controller,
      interactive: true,
      thickness: 12,
      radius: const Radius.circular(6),
      thumbColor: thumb,
      trackVisibility: false,
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
    final meta = _lineMeta(widget.result);
    final rows = computeAlignedRows(widget.result.entries);
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
          child: _scrollbar(
            context: context,
            controller: widget.controller,
            child: ListView.builder(
              key: const Key('side-by-side-list'),
              controller: widget.controller,
              itemCount: rows.length,
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
                  row = _alignedRow(
                      ctx, widget.result.entries[ei], meta[ei], c, isCurrent);
                  keyOwners = <int>[ei];
                } else {
                  final ei = spec.ins!;
                  row = _alignedRow(
                      ctx, widget.result.entries[ei], meta[ei], c, isCurrent);
                  keyOwners = <int>[ei];
                }
                Widget out = row;
                for (final k in keyOwners) {
                  final key = widget.rowKeysByEntry?[k];
                  if (key != null) out = KeyedSubtree(key: key, child: out);
                }
                if (widget.onLongPressEntry != null) {
                  out = GestureDetector(
                    onLongPress: () => widget.onLongPressEntry!(keyOwners),
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

  // ============ 独立滚动 ============

  Widget _buildIndependent(BuildContext context, DiffColors c) {
    final meta = _lineMeta(widget.result);
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
                child: _scrollbar(
                  context: context,
                  controller: _leftCtrl,
                  child: ListView.builder(
                    key: const Key('sbs-left-list'),
                    controller: _leftCtrl,
                    itemCount: leftIndices.length,
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
                      if (widget.onLongPressEntry == null) return tile;
                      return GestureDetector(
                        onLongPress: () =>
                            widget.onLongPressEntry!(<int>[ei]),
                        behavior: HitTestBehavior.opaque,
                        child: tile,
                      );
                    },
                  ),
                ),
              ),
              divider,
              Expanded(
                child: _scrollbar(
                  context: context,
                  controller: _rightCtrl,
                  child: ListView.builder(
                    key: const Key('sbs-right-list'),
                    controller: _rightCtrl,
                    itemCount: rightIndices.length,
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
                      if (widget.onLongPressEntry == null) return tile;
                      return GestureDetector(
                        onLongPress: () =>
                            widget.onLongPressEntry!(<int>[ei]),
                        behavior: HitTestBehavior.opaque,
                        child: tile,
                      );
                    },
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
      matchOrange: SideBySideView._matchOrange,
      charDiff: null,
      showLineNumbers: widget.showLineNumbers,
      bodyFontSize: widget.bodyFontSize,
      gutterFontSize: widget.gutterFontSize,
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
            matchOrange: SideBySideView._matchOrange,
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
            matchOrange: SideBySideView._matchOrange,
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
            matchOrange: SideBySideView._matchOrange,
            charDiff: leftCharDiff,
            showLineNumbers: widget.showLineNumbers,
            bodyFontSize: widget.bodyFontSize,
            gutterFontSize: widget.gutterFontSize,
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
            matchOrange: SideBySideView._matchOrange,
            charDiff: rightCharDiff,
            showLineNumbers: widget.showLineNumbers,
            bodyFontSize: widget.bodyFontSize,
            gutterFontSize: widget.gutterFontSize,
          ),
        ),
      ],
    );
  }
}
