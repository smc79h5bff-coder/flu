import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 每项的高度表 + 前缀和，用于精确滚动定位。
class LineHeightTable {
  LineHeightTable._(this._heights, this._prefixSum, this._totalHeight);

  final Float64List _heights;
  final Float64List _prefixSum;
  final double _totalHeight;

  int get length => _heights.length;
  double get totalHeight => _totalHeight;

  double heightOf(int index) {
    if (index < 0 || index >= _heights.length) return 0;
    return _heights[index];
  }

  double offsetOf(int index) {
    if (index <= 0) return 0;
    if (index >= _prefixSum.length) return _totalHeight;
    return _prefixSum[index];
  }

  int indexAt(double offset) {
    if (_heights.isEmpty) return 0;
    if (offset <= 0) return 0;
    if (offset >= _totalHeight) return _heights.length - 1;
    var lo = 0;
    var hi = _heights.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (_prefixSum[mid] <= offset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo;
  }

  factory LineHeightTable.fromHeights(List<double> heights) {
    final n = heights.length;
    if (n == 0) {
      return LineHeightTable._(Float64List(0), Float64List(1), 0.0);
    }
    final h = Float64List(n);
    final ps = Float64List(n + 1);
    var sum = 0.0;
    for (var i = 0; i < n; i++) {
      h[i] = heights[i];
      ps[i] = sum;
      sum += heights[i];
    }
    ps[n] = sum;
    return LineHeightTable._(h, ps, sum);
  }

  static final LineHeightTable empty =
      LineHeightTable.fromHeights(const <double>[]);

  int get approxByteSize =>
      _heights.lengthInBytes + _prefixSum.lengthInBytes;
}

// ========== TextPainter 单例（复用同一个，避免每行创建对象） ==========

final TextPainter _tp = TextPainter(textDirection: ui.TextDirection.ltr);

/// 单行文本折行后的高度（像素）。
double measureTextHeight({
  required String text,
  required double maxWidth,
  required TextStyle style,
  required TextScaler textScaler,
  bool noWrap = false,
  double extraVerticalPadding = 0,
}) {
  if (maxWidth <= 0) return 0;
  final effective = text.isEmpty ? ' ' : text;

  _tp.text = TextSpan(text: effective, style: style);
  _tp.textScaler = textScaler;
  _tp.maxLines = noWrap ? 1 : null;
  _tp.ellipsis = noWrap ? '\u2026' : null;

  _tp.layout(maxWidth: maxWidth);
  final h = _tp.height + extraVerticalPadding;
  return h;
}

/// 单行高度：所有行显示 1 行时的固定高度。
double _singleLineHeight(TextStyle style, TextScaler textScaler) {
  final fs = style.fontSize ?? 14.0;
  final lh = style.height ?? 1.0;
  return textScaler.scale(fs) * lh;
}

/// 主线程让出的安全阈值。累计计算超过这个时长就让出一次，防止 ANR。
/// Android 5 秒判定无响应，我们提前到 4 秒。
const int _yieldThresholdMs = 4000;

/// 分帧计算一批文本的高度表。
///
/// **方案乙**：全程跑完只在超过 [_yieldThresholdMs] 时让出一次主线程，
/// 让出后计时归零。小文件（1~3 万行）几乎不让出，一次算完最快；
/// 大文件也不至于 ANR。
Future<LineHeightTable> computeLineHeights({
  required int itemCount,
  required double Function(int index) widthForItem,
  required String Function(int index) textForItem,
  required TextStyle style,
  required TextScaler textScaler,
  bool noWrap = false,
  double extraVerticalPadding = 0,
  void Function(int done, int total)? onProgress,
}) async {
  if (itemCount == 0) return LineHeightTable.empty;

  // 不换行模式：所有行高度一样，O(1)。
  if (noWrap) {
    final w = widthForItem(0);
    final h = _singleLineHeight(style, textScaler) + extraVerticalPadding;
    final measured = measureTextHeight(
      text: 'M',
      maxWidth: w,
      style: style,
      textScaler: textScaler,
      noWrap: true,
      extraVerticalPadding: extraVerticalPadding,
    );
    final finalH = measured > 0 ? measured : h;
    final heights = List<double>.filled(itemCount, finalH);
    onProgress?.call(itemCount, itemCount);
    return LineHeightTable.fromHeights(heights);
  }

  final heights = List<double>.filled(itemCount, 0);
  final sw = Stopwatch()..start();
  final w = widthForItem(0);

  for (var i = 0; i < itemCount; i++) {
    heights[i] = measureTextHeight(
      text: textForItem(i),
      maxWidth: w,
      style: style,
      textScaler: textScaler,
      noWrap: false,
      extraVerticalPadding: extraVerticalPadding,
    );

    // 每 500 行检查一次计时器，避免每行都查（查也有一点开销）。
    if ((i & 0x1FF) == 0x1FF && sw.elapsedMilliseconds >= _yieldThresholdMs) {
      onProgress?.call(i + 1, itemCount);
      await Future<void>.delayed(Duration.zero);
      sw.reset();
    }
  }

  onProgress?.call(itemCount, itemCount);
  return LineHeightTable.fromHeights(heights);
}

/// 并排 / 仅差异模式：每一行有两栏，高度取两栏的较大值。
///
/// [styleForItem] / [noWrapForItem]：可选。传了的话，每一行可以用不同的
/// 字号 / 换行策略（例如"相同行不换行 + 小字号"）。不传就用全局的
/// [style] / [noWrap]，行为和以前完全一样。
Future<LineHeightTable> computeLineHeightsForTwoPane({
  required int itemCount,
  required double leftWidth,
  required double rightWidth,
  required String Function(int index) leftTextForItem,
  required String Function(int index) rightTextForItem,
  required TextStyle style,
  required TextScaler textScaler,
  bool noWrap = false,
  double extraVerticalPadding = 0,
  TextStyle? Function(int index)? styleForItem,
  bool? Function(int index)? noWrapForItem,
  void Function(int done, int total)? onProgress,
}) async {
  if (itemCount == 0) return LineHeightTable.empty;

  // 有 override → 逐行独立计算。
  if (styleForItem != null || noWrapForItem != null) {
    final heights = List<double>.filled(itemCount, 0);
    final sw = Stopwatch()..start();
    for (var i = 0; i < itemCount; i++) {
      final s = styleForItem?.call(i) ?? style;
      final nw = noWrapForItem?.call(i) ?? noWrap;
      final lt = leftTextForItem(i);
      final rt = rightTextForItem(i);

      if (nw) {
        final hL = measureTextHeight(
          text: lt,
          maxWidth: leftWidth,
          style: s,
          textScaler: textScaler,
          noWrap: true,
          extraVerticalPadding: extraVerticalPadding,
        );
        final hR = measureTextHeight(
          text: rt,
          maxWidth: rightWidth,
          style: s,
          textScaler: textScaler,
          noWrap: true,
          extraVerticalPadding: extraVerticalPadding,
        );
        heights[i] = hL > hR ? hL : hR;
      } else if (lt == rt) {
        heights[i] = measureTextHeight(
          text: lt,
          maxWidth: leftWidth,
          style: s,
          textScaler: textScaler,
          noWrap: false,
          extraVerticalPadding: extraVerticalPadding,
        );
      } else {
        final hL = measureTextHeight(
          text: lt,
          maxWidth: leftWidth,
          style: s,
          textScaler: textScaler,
          noWrap: false,
          extraVerticalPadding: extraVerticalPadding,
        );
        final hR = measureTextHeight(
          text: rt,
          maxWidth: rightWidth,
          style: s,
          textScaler: textScaler,
          noWrap: false,
          extraVerticalPadding: extraVerticalPadding,
        );
        heights[i] = hL > hR ? hL : hR;
      }

      if ((i & 0x1FF) == 0x1FF &&
          sw.elapsedMilliseconds >= _yieldThresholdMs) {
        onProgress?.call(i + 1, itemCount);
        await Future<void>.delayed(Duration.zero);
        sw.reset();
      }
    }
    onProgress?.call(itemCount, itemCount);
    return LineHeightTable.fromHeights(heights);
  }

  // 无 override → 走原来的快路径，行为不变。
  if (noWrap) {
    final hL = measureTextHeight(
      text: 'M',
      maxWidth: leftWidth,
      style: style,
      textScaler: textScaler,
      noWrap: true,
      extraVerticalPadding: extraVerticalPadding,
    );
    final hR = measureTextHeight(
      text: 'M',
      maxWidth: rightWidth,
      style: style,
      textScaler: textScaler,
      noWrap: true,
      extraVerticalPadding: extraVerticalPadding,
    );
    final h = hL > hR ? hL : hR;
    final heights = List<double>.filled(itemCount, h);
    onProgress?.call(itemCount, itemCount);
    return LineHeightTable.fromHeights(heights);
  }

  final heights = List<double>.filled(itemCount, 0);
  final sw = Stopwatch()..start();

  for (var i = 0; i < itemCount; i++) {
    final lt = leftTextForItem(i);
    final rt = rightTextForItem(i);

    if (lt == rt) {
      heights[i] = measureTextHeight(
        text: lt,
        maxWidth: leftWidth,
        style: style,
        textScaler: textScaler,
        noWrap: false,
        extraVerticalPadding: extraVerticalPadding,
      );
    } else {
      final hL = measureTextHeight(
        text: lt,
        maxWidth: leftWidth,
        style: style,
        textScaler: textScaler,
        noWrap: false,
        extraVerticalPadding: extraVerticalPadding,
      );
      final hR = measureTextHeight(
        text: rt,
        maxWidth: rightWidth,
        style: style,
        textScaler: textScaler,
        noWrap: false,
        extraVerticalPadding: extraVerticalPadding,
      );
      heights[i] = hL > hR ? hL : hR;
    }

    if ((i & 0x1FF) == 0x1FF && sw.elapsedMilliseconds >= _yieldThresholdMs) {
      onProgress?.call(i + 1, itemCount);
      await Future<void>.delayed(Duration.zero);
      sw.reset();
    }
  }

  onProgress?.call(itemCount, itemCount);
  return LineHeightTable.fromHeights(heights);
}
