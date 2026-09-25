import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

import '../../../../core/constants/app_colors.dart';
import '../../../diff/domain/diff_entry.dart';
import '../../../diff/domain/diff_operation.dart';
import '../../../diff/domain/diff_result.dart';
import 'inline_char_diff.dart';

/// Merged single-pane view: original + modified interleaved.
class MergedView extends ConsumerWidget {
  const MergedView({
    required this.result,
    required this.itemScrollController,
    required this.itemPositionsListener,
    this.lineNumbers = true,
    this.findQuery = '',
    this.currentMatchEntry,
    this.showLineNumbers = true,
    this.bodyFontSize = 14.0,
    this.gutterFontSize = 11.0,
    this.noWrap = false,
    this.onLongPressEntry,
    super.key,
  });

  final DiffResult result;
  final ItemScrollController itemScrollController;
  final ItemPositionsListener itemPositionsListener;
  final bool lineNumbers;
  final String findQuery;
  final int? currentMatchEntry;
  final bool showLineNumbers;
  final double bodyFontSize;
  final double gutterFontSize;
  final bool noWrap;
  final void Function(int entryIndex)? onLongPressEntry;

  static const Color _matchYellow = Color(0xFFFFF59D);
  static const Color _matchPink = Color(0xFFFF4081);

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final meta = cachedMergedMeta(result);
    final order = cachedMergedOrder(result);

    return ScrollablePositionedList.builder(
      itemScrollController: itemScrollController,
      itemPositionsListener: itemPositionsListener,
      padding: const EdgeInsets.symmetric(vertical: 2),
      itemCount: order.length,
      itemBuilder: (ctx, i) {
        final ei = order[i];
        final e = result.entries[ei];
        final isCurrent =
            currentMatchEntry != null && ei == currentMatchEntry;
        final tile = _EntryTile(
          entry: e,
          lineNumber: lineNumbers ? meta[ei].orig : 0,
          findQuery: findQuery,
          isCurrentMatch: isCurrent,
          matchYellow: _matchYellow,
          matchPink: _matchPink,
          showLineNumbers: showLineNumbers,
          bodyFontSize: bodyFontSize,
          gutterFontSize: gutterFontSize,
          noWrap: noWrap,
        );
        final wrapped = onLongPressEntry == null
            ? tile
            : GestureDetector(
                onLongPress: () => onLongPressEntry!(ei),
                behavior: HitTestBehavior.opaque,
                child: tile,
              );
        return KeyedSubtree(key: ValueKey<int>(ei), child: wrapped);
      },
    );
  }
}

// ========== 派生数据缓存 ==========

DiffResult? _lastMergedMetaFor;
List<({int orig, int mod})>? _lastMergedMeta;

List<({int orig, int mod})> cachedMergedMeta(DiffResult result) {
  if (identical(_lastMergedMetaFor, result) && _lastMergedMeta != null) {
    return _lastMergedMeta!;
  }
  final meta = <({int orig, int mod})>[];
  var o = 0, m = 0;
  for (final e in result.entries) {
    meta.add((orig: o, mod: m));
    if (e.operation == DiffOperation.equal ||
        e.operation == DiffOperation.delete) o++;
    if (e.operation == DiffOperation.equal ||
        e.operation == DiffOperation.insert) m++;
  }
  _lastMergedMeta = meta;
  _lastMergedMetaFor = result;
  return meta;
}

DiffResult? _lastMergedOrderFor;
List<int>? _lastMergedOrder;

List<int> cachedMergedOrder(DiffResult result) {
  if (identical(_lastMergedOrderFor, result) && _lastMergedOrder != null) {
    return _lastMergedOrder!;
  }
  _lastMergedOrder = _mergedOrder(result.entries);
  _lastMergedOrderFor = result;
  return _lastMergedOrder!;
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

// ========== 查找高亮 spans 的 LRU 缓存 ==========

const int _spansCacheCap = 512;
final Map<String, List<InlineSpan>> _spansCache =
    <String, List<InlineSpan>>{};

List<InlineSpan> _cachedSpans(
  String text,
  String findQuery,
  bool isCurrentMatch,
  Color matchYellow,
  Color matchPink,
) {
  final key = '$text\u0000$findQuery\u0000${isCurrentMatch ? 1 : 0}';
  final hit = _spansCache[key];
  if (hit != null) return hit;

  final spans =
      _buildSpans(text, findQuery, isCurrentMatch, matchYellow, matchPink);
  if (_spansCache.length >= _spansCacheCap) {
    _spansCache.clear();
  }
  _spansCache[key] = spans;
  return spans;
}

List<InlineSpan> _buildSpans(
  String text,
  String findQuery,
  bool isCurrentMatch,
  Color matchYellow,
  Color matchPink,
) {
  final q = findQuery;
  if (q.isEmpty || text.isEmpty) {
    return <InlineSpan>[TextSpan(text: text)];
  }
  final bg = isCurrentMatch ? matchPink : matchYellow;
  final spans = <InlineSpan>[];
  var start = 0;
  int idx;
  while (start <= text.length && (idx = text.indexOf(q, start)) != -1) {
    if (idx > start) spans.add(TextSpan(text: text.substring(start, idx)));
    spans.add(TextSpan(
      text: q,
      style: TextStyle(backgroundColor: bg, fontWeight: FontWeight.bold),
    ));
    start = idx + q.length;
  }
  if (start < text.length) spans.add(TextSpan(text: text.substring(start)));
  return spans.isEmpty ? <InlineSpan>[TextSpan(text: text)] : spans;
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({
    required this.entry,
    required this.lineNumber,
    required this.findQuery,
    required this.isCurrentMatch,
    required this.matchYellow,
    required this.matchPink,
    required this.showLineNumbers,
    required this.bodyFontSize,
    required this.gutterFontSize,
    required this.noWrap,
  });

  final DiffEntry entry;
  final int lineNumber;
  final String findQuery;
  final bool isCurrentMatch;
  final Color matchYellow;
  final Color matchPink;
  final bool showLineNumbers;
  final double bodyFontSize;
  final double gutterFontSize;
  final bool noWrap;

  @override
  Widget build(BuildContext context) {
    final defaultFg = Theme.of(context).textTheme.bodyMedium?.color;
    final outline = Theme.of(context).colorScheme.outline;

    final Widget row = switch (entry.operation) {
      DiffOperation.equal => _plain(
          context,
          text: entry.text,
          color: defaultFg,
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

    if (!showLineNumbers || lineNumber <= 0) return row;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 30,
          child: Padding(
            padding: const EdgeInsets.only(top: 6, right: 4),
            child: Text(
              '$lineNumber',
              textAlign: TextAlign.end,
              style: TextStyle(fontSize: gutterFontSize, color: outline),
            ),
          ),
        ),
        Expanded(child: row),
      ],
    );
  }

  Widget _plain(BuildContext context, {required String text, Color? color}) {
    final style = TextStyle(
      fontSize: bodyFontSize,
      color: color,
      height: 1.35,
    );
    final spans = findQuery.isEmpty
        ? <InlineSpan>[TextSpan(text: text.isEmpty ? ' ' : text)]
        : _cachedSpans(
            text, findQuery, isCurrentMatch, matchYellow, matchPink);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      child: noWrap
          ? Text.rich(
              TextSpan(style: style, children: spans),
              softWrap: false,
              overflow: TextOverflow.clip,
              maxLines: 1,
            )
          : Text.rich(TextSpan(style: style, children: spans)),
    );
  }

  Widget _highlighted(
    BuildContext context, {
    required String text,
    required Color color,
    required String symbol,
    String? charDiffBefore,
    String? charDiffAfter,
    bool charDiffSide = true,
  }) {
    final style = TextStyle(
      fontSize: bodyFontSize,
      color: color,
      height: 1.35,
    );

    final Widget content =
        (charDiffAfter != null && charDiffBefore != null)
            ? InlineCharDiff(
                before: charDiffBefore,
                after: charDiffAfter,
                side: charDiffSide,
                style: style,
                findQuery: findQuery,
                isCurrentMatch: isCurrentMatch,
              )
            : (noWrap
                ? Text.rich(
                    TextSpan(
                      style: style,
                      children: _cachedSpans(text, findQuery, isCurrentMatch,
                          matchYellow, matchPink),
                    ),
                    softWrap: false,
                    overflow: TextOverflow.clip,
                    maxLines: 1,
                  )
                : Text.rich(TextSpan(
                    style: style,
                    children: _cachedSpans(text, findQuery, isCurrentMatch,
                        matchYellow, matchPink),
                  )));

    return Padding(
      padding: const EdgeInsets.only(right: 2, top: 1, bottom: 1),
      child: ColoredBox(
        color: color.withValues(alpha: 0.18),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(width: 3, color: color),
            const SizedBox(width: 4),
            if (showLineNumbers && symbol.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(
                  symbol,
                  style: TextStyle(
                    color: color,
                    fontWeight: FontWeight.bold,
                    fontSize: bodyFontSize,
                  ),
                ),
              ),
            const SizedBox(width: 4),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: content,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
