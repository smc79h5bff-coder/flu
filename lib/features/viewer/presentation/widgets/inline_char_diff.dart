import 'package:flutter/material.dart';

import '../../../diff/application/diff_cache.dart';

/// Backwards-compatible free function. Routes to the session cache so callers
/// that still import this symbol keep working.
List<CharSeg> charSegments(String a, String b) =>
    DiffCache.instance.charSegments(a, b);

/// Renders a character-level diff between [before] and [after] for one side
/// of a "replace" row.
///
/// - side == false (left, old): added segments are hidden, deleted segments
///   are shown with red strike-through.
/// - side == true  (right, new): deleted segments are hidden, added segments
///   are shown with green underline.
///
/// Segments are fetched from [DiffCache] so the same (before, after) pair is
/// diffed only once per session, even across many rebuilds.
class InlineCharDiff extends StatelessWidget {
  const InlineCharDiff({
    super.key,
    required this.before,
    required this.after,
    required this.side,
    this.style,
    this.findQuery = '',
  });

  final String before;
  final String after;
  final bool side; // true = right (new), false = left (old)
  final TextStyle? style;

  /// Optional search term: hits get a yellow background (on top of the
  /// red/green character-diff styling) so find-highlight and char-diff can
  /// coexist visually.
  final String findQuery;

  @override
  Widget build(BuildContext context) {
    final segs = DiffCache.instance.charSegments(before, after);
    final base = style ?? Theme.of(context).textTheme.bodyMedium!;
    final addedStyle = base.copyWith(
      color: Colors.green.shade700,
      backgroundColor: Colors.green.withValues(alpha: .18),
      decoration: TextDecoration.underline,
      decorationColor: Colors.green,
    );
    final removedStyle = base.copyWith(
      color: Colors.red.shade700,
      backgroundColor: Colors.red.withValues(alpha: .18),
      decoration: TextDecoration.lineThrough,
      decorationColor: Colors.red,
    );

    final spans = <TextSpan>[];
    for (final (op, text) in segs) {
      // Right side keeps equal + insert; left side keeps equal + delete.
      final show = side ? op != -1 : op != 1;
      if (!show) continue;
      final segHighlight = side
          ? (op == 1 ? addedStyle : null)
          : (op == -1 ? removedStyle : null);
      if (findQuery.isEmpty || text.isEmpty) {
        spans.add(TextSpan(text: text, style: segHighlight));
        continue;
      }
      // Sub-split each segment by findQuery so yellow highlight coexists
      // with the red/green char-diff styling.
      var start = 0;
      int idx;
      while (start <= text.length &&
          (idx = text.indexOf(findQuery, start)) != -1) {
        if (idx > start) {
          spans.add(TextSpan(
            text: text.substring(start, idx),
            style: segHighlight,
          ));
        }
        final matchedStyle = (segHighlight ?? base).copyWith(
          backgroundColor: const Color(0xFFFFF59D),
          fontWeight: FontWeight.bold,
        );
        spans.add(TextSpan(text: findQuery, style: matchedStyle));
        start = idx + findQuery.length;
      }
      if (start < text.length) {
        spans.add(TextSpan(
          text: text.substring(start),
          style: segHighlight,
        ));
      }
    }
    return Text.rich(
      TextSpan(style: base, children: spans),
      maxLines: 3,
      overflow: TextOverflow.ellipsis,
    );
  }
}