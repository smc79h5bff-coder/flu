import 'package:flutter/material.dart';

import '../../../diff/application/diff_cache.dart';

List<CharSeg> charSegments(String a, String b) =>
    DiffCache.instance.charSegments(a, b);

/// 字符级差异渲染。**不加下划线、不加删除线**，只用字体色 + 背景色区分。
/// 颜色由调用方传入；不传时使用内置红/绿。
class InlineCharDiff extends StatelessWidget {
  const InlineCharDiff({
    super.key,
    required this.before,
    required this.after,
    required this.side,
    this.style,
    this.findQuery = '',
    this.isCurrentMatch = false,
    this.addedFg,
    this.addedBg,
    this.removedFg,
    this.removedBg,
  });

  final String before;
  final String after;

  /// true = 右侧（新文本）；false = 左侧（旧文本）。
  final bool side;
  final TextStyle? style;
  final String findQuery;

  /// 是否是"当前停留的匹配项"。为 true 时，命中的查找词用橙色高亮，
  /// 其它匹配仍用黄色。
  final bool isCurrentMatch;

  final Color? addedFg;
  final Color? addedBg;
  final Color? removedFg;
  final Color? removedBg;

  /// 普通匹配：浅黄。
  static const Color _matchYellow = Color(0xFFFFF59D);

  /// 当前匹配：橙色。
  static const Color _matchOrange = Color(0xFFFF9800);

  @override
  Widget build(BuildContext context) {
    final segs = DiffCache.instance.charSegments(before, after);
    final base = style ?? Theme.of(context).textTheme.bodyMedium!;
    final addedStyle = base.copyWith(
      color: addedFg ?? Colors.green.shade700,
      backgroundColor: addedBg ?? Colors.green.withValues(alpha: .18),
    );
    final removedStyle = base.copyWith(
      color: removedFg ?? Colors.red.shade700,
      backgroundColor: removedBg ?? Colors.red.withValues(alpha: .18),
    );

    final matchBg = isCurrentMatch ? _matchOrange : _matchYellow;

    final spans = <TextSpan>[];
    for (final (op, text) in segs) {
      final show = side ? op != -1 : op != 1;
      if (!show) continue;
      final segHighlight = side
          ? (op == 1 ? addedStyle : null)
          : (op == -1 ? removedStyle : null);
      if (findQuery.isEmpty || text.isEmpty) {
        spans.add(TextSpan(text: text, style: segHighlight));
        continue;
      }
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
          backgroundColor: matchBg,
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
    return Text.rich(TextSpan(style: base, children: spans));
  }
}
