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
    this.showLineNumbers = true,
    this.bodyFontSize = 14.0,
    this.gutterFontSize = 11.0,
    super.key,
  });

  final DiffResult result;
  final ScrollController? controller;
  final bool lineNumbers;
  final String findQuery;
  final Map<int, GlobalKey>? rowKeysByEntry;
  final bool showLineNumbers;
  final double bodyFontSize;
  final double gutterFontSize;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final meta = <({int orig, int mod})>[];
    var o = 0, m = 0;
    for (final e in result.entries) {
      meta.add((orig: o, mod: m));
      if (e.operation == DiffOperation.equal ||
          e.operation == DiffOperation.delete) o++;
      if (e.operation == DiffOperation.equal ||
          e.operation == DiffOperation.insert) m++;
    }

    final order = _mergedOrder(result.entries);

    return Scrollbar(
      controller: controller,
      thumbVisibility: false,
      child: ListView.builder(
        controller: controller,
        padding: const EdgeInsets.symmetric(vertical: 8),
        itemCount: order.length,
        itemBuilder: (ctx, i) {
          final ei = order[i];
          final e = result.entries[ei];
          final tile = _EntryTile(
            entry: e,
            lineNumber: lineNumbers ? meta[ei].orig : 0,
            findQuery: findQuery,
            showLineNumbers: showLineNumbers,
            bodyFontSize: bodyFontSize,
            gutterFontSize: gutterFontSize,
          );
          final key = rowKeysByEntry?[ei];
          return key == null ? tile : KeyedSubtree(key: key, child: tile);
        },
      ),
    );
  }
}

List<int> _mergedOrder(List<DiffEntry> entries) {
  final order = <int>[];
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
        order.add(delStart + k);
        order.add(insStart + k);
      }
      for (var k = pairs; k < delCount; k++) {
        order.add(delStart + k);
      }
      for (var k = pairs; k < insCount; k++) {
        order.add(insStart + k);
      }
    } else {
      order.add(i);
      i++;
    }
  }
  return order;
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({
    required this.entry,
    required this.lineNumber,
    required this.findQuery,
    required this.showLineNumbers,
    required this.bodyFontSize,
    required this.gutterFontSize,
  });

  final DiffEntry entry;
  final int lineNumber;
  final String findQuery;
  final bool showLineNumbers;
  final double bodyFontSize;
  final double gutterFontSize;

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

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showLineNumbers && lineNumber > 0)
          Container(
            width: 34,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            alignment: Alignment.topCenter,
            child: Text(
              '$lineNumber',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: gutterFontSize,
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
          style: TextStyle(fontSize: bodyFontSize, color: color, height: 1.1),
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
      fontSize: bodyFontSize,
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
        color: color.withOpacity(0.25),
        border: Border(left: BorderSide(color: color, width: 3)),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showLineNumbers && symbol.isNotEmpty) ...[
            Text(symbol,
                style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.bold,
                    fontSize: bodyFontSize)),
            const SizedBox(width: 8),
          ],
          Expanded(child: content),
        ],
      ),
    );
  }

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
