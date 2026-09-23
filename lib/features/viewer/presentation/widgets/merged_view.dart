import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../diff/domain/diff_entry.dart';
import '../../../diff/domain/diff_operation.dart';
import '../../../diff/domain/diff_result.dart';
import 'inline_char_diff.dart';

/// Merged single-pane view: original + modified interleaved.
/// PRD §2 Module 6.
class MergedView extends ConsumerWidget {
  const MergedView({
    required this.result,
    this.controller,
    this.lineNumbers = true,
    this.findQuery = '',
    this.rowKeysByEntry,
    super.key,
  });

  final DiffResult result;

  /// Optional scroll controller; when attached, the parent screen can drive
  /// programmatic jumps to the next/previous diff entry.
  final ScrollController? controller;

  /// Show a per-entry line-number gutter (original side for equal/delete,
  /// modified side for equal/insert).
  final bool lineNumbers;

  /// When non-empty, matching substrings inside each entry are highlighted.
  final String findQuery;

  /// Optional per-entry [GlobalKey]s (by entry index) used by the parent to
  /// scroll precisely to search/diff hits via [Scrollable.ensureVisible].
  final Map<int, GlobalKey>? rowKeysByEntry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Precompute the running line number for each side at every entry.
    final meta = <({int orig, int mod})>[];
    var o = 0, m = 0;
    for (final e in result.entries) {
      meta.add((orig: o, mod: m));
      if (e.operation == DiffOperation.equal || e.operation == DiffOperation.delete) o++;
      if (e.operation == DiffOperation.equal || e.operation == DiffOperation.insert) m++;
    }

    return ListView.builder(
      controller: controller,
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: result.entries.length,
      itemBuilder: (ctx, i) {
        final e = result.entries[i];
        final tile = _EntryTile(
          entry: e,
          lineNumber: lineNumbers ? meta[i].orig : 0,
          findQuery: findQuery,
        );
        final key = rowKeysByEntry?[i];
        return key == null ? tile : KeyedSubtree(key: key, child: tile);
      },
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({
    required this.entry,
    required this.lineNumber,
    required this.findQuery,
  });

  final DiffEntry entry;
  final int lineNumber;
  final String findQuery;

  @override
  Widget build(BuildContext context) {
    final row = switch (entry.operation) {
      DiffOperation.equal => _plain(
          context,
          text: entry.text,
          color: Theme.of(context).textTheme.bodyMedium?.color,
        ),
      DiffOperation.insert => _highlighted(
          context,
          text: entry.text,
          color: AppColors.addedOf(context),
          symbol: '+',
        ),
      DiffOperation.delete => _highlighted(
          context,
          text: entry.text,
          color: AppColors.deletedOf(context),
          symbol: '-',
          strikeThrough: true,
        ),
      DiffOperation.replace => _highlighted(
          context,
          text: entry.text,
          color: AppColors.modifiedOf(context),
          symbol: '~',
          charDiffBefore: entry.oldText,
          charDiffAfter: entry.newText.isEmpty ? entry.text : entry.newText,
          charDiffSide: true,
        ),
    };

    // NOTE: We intentionally avoid `IntrinsicHeight` here. IntrinsicHeight
    // forces a second measure pass per tile, which is the single biggest
    // ListView scrolling cost in this screen. `CrossAxisAlignment.start`
    // gives the same visual layout (gutter aligned to top) with one measure.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (lineNumber > 0)
          Container(
            width: 30,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            alignment: Alignment.topCenter,
            child: Text(
              '$lineNumber',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.outline,
                  ),
            ),
          ),
        Expanded(child: row),
      ],
    );
  }

  Widget _plain(BuildContext context, {required String text, Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: RichText(
        text: TextSpan(
          style: TextStyle(fontSize: 14, color: color, height: 1.4),
          children: _spans(text),
        ),
      ),
    );
  }

  Widget _highlighted(
    BuildContext context, {
    required String text,
    required Color color,
    required String symbol,
    bool strikeThrough = false,
    String? charDiffBefore,
    String? charDiffAfter,
    bool charDiffSide = true,
  }) {
    final style = TextStyle(
      fontSize: 14,
      color: color,
      height: 1.4,
      decoration: strikeThrough ? TextDecoration.lineThrough : null,
    );
    final Widget content = (charDiffAfter != null && charDiffBefore != null)
        ? InlineCharDiff(
            before: charDiffBefore,
            after: charDiffAfter,
            side: charDiffSide,
            style: style,
            findQuery: findQuery,
          )
        : RichText(
            text: TextSpan(style: style, children: _spans(text)),
          );

    return Container(
      margin: const EdgeInsets.only(right: 8, top: 2, bottom: 2),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        // 0.25 keeps the highlight clearly visible in light theme while
        // still letting the base text color through. 0.12 (previous value)
        // was too faint against the light scaffold background.
        color: color.withOpacity(0.25),
        border: Border(left: BorderSide(color: color, width: 3)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(symbol,
              style: TextStyle(
                  color: color, fontWeight: FontWeight.bold, fontSize: 14)),
          const SizedBox(width: 8),
          Expanded(child: content),
        ],
      ),
    );
  }

  /// Split [text] by [findQuery], wrapping hits with a yellow background so
  /// the active search term is visible inside the (possibly colored) entry.
  List<InlineSpan> _spans(String text) {
    final q = findQuery;
    if (q.isEmpty || text.isEmpty) return [TextSpan(text: text)];
    final spans = <InlineSpan>[];
    var start = 0;
    int idx;
    while (start <= text.length && (idx = text.indexOf(q, start)) != -1) {
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
    return spans.isEmpty ? [TextSpan(text: text)] : spans;
  }
}
