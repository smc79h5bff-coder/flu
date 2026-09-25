import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// 每项的高度表 + 前缀和，用于精确滚动定位。
///
/// 有了它：
///   - ListView 可以精确知道每项多高 → 滚动条 thumb 位置准确
///   - 跳转到第 N 项 → 直接查前缀和，offset 精确到像素
///   - 从 pixels 反查"现在屏幕顶上是第几项" → 二分查找，不再估算
class LineHeightTable {
  LineHeightTable._(this._heights, this._prefixSum, this._totalHeight);

  final Float64List _heights;
  /// prefixSum[i] = sum(heights[0..i-1])，prefixSum[0] = 0
  /// 长度 = heights.length + 1
  final Float64List _prefixSum;
  final double _totalHeight;

  int get length => _heights.length;
  double get totalHeight => _totalHeight;

  double heightOf(int index) {
    if (index < 0 || index >= _heights.length) return 0;
    return _heights[index];
  }

  /// 第 index 项在滚动坐标里的起始 offset。
  double offsetOf(int index) {
    if (index <= 0) return 0;
    if (index >= _prefixSum.length) return _totalHeight;
    return _prefixSum[index];
  }

  /// 给定滚动 offset，返回所在项的 index（二分查找）。
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
      return LineHeightTable._(
        Float64List(0),
        Float64List(1),
        0.0,
      );
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
  
  /// 内存占用（估算，用于缓存淘汰策略）。
  int get approxByteSize => _heights.lengthInBytes + _prefixSum.lengthInBytes;
}

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
  final tp = TextPainter(
    text: TextSpan(
      text: text.isEmpty ? ' ' : text,
      style: style,
    ),
    textDirection: ui.TextDirection.ltr,
    textScaler: textScaler,
    maxLines: noWrap ? 1 : null,
    ellipsis: noWrap ? '\u2026' : null,
  );
  tp.layout(maxWidth: maxWidth);
  final h = tp.height + extraVerticalPadding;
  tp.dispose();
  return h;
}

/// 分帧计算一批文本的高度表。
///
/// 每帧算 [chunkSize] 项，然后让出主线程一次，避免长任务卡 UI。
/// 1 万行大约 300~500ms 完成，期间 UI 不会卡（只是慢一点）。
///
/// 返回的 Future 完成时返回最终的 [LineHeightTable]。
Future<LineHeightTable> computeLineHeights({
  required int itemCount,
  required double Function(int index) widthForItem,
  required String Function(int index) textForItem,
  required TextStyle style,
  required TextScaler textScaler,
  bool noWrap = false,
  double extraVerticalPadding = 0,
  int chunkSize = 300,
  void Function(int done, int total)? onProgress,
}) async {
  final heights = List<double>.filled(itemCount, 0);
  for (var start = 0; start < itemCount; start += chunkSize) {
    final end = start + chunkSize < itemCount ? start + chunkSize : itemCount;
    for (var i = start; i < end; i++) {
      heights[i] = measureTextHeight(
        text: textForItem(i),
        maxWidth: widthForItem(i),
        style: style,
        textScaler: textScaler,
        noWrap: noWrap,
        extraVerticalPadding: extraVerticalPadding,
      );
    }
    onProgress?.call(end, itemCount);
    // 让出主线程一帧，避免长任务卡住手势和动画。
    await Future<void>.delayed(Duration.zero);
  }
  return LineHeightTable.fromHeights(heights);
}

/// 并排 / 仅差异模式：每一行有两栏，高度取两栏的较大值。
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
  int chunkSize = 300,
  void Function(int done, int total)? onProgress,
}) async {
  final heights = List<double>.filled(itemCount, 0);
  for (var start = 0; start < itemCount; start += chunkSize) {
    final end = start + chunkSize < itemCount ? start + chunkSize : itemCount;
    for (var i = start; i < end; i++) {
      final hL = measureTextHeight(
        text: leftTextForItem(i),
        maxWidth: leftWidth,
        style: style,
        textScaler: textScaler,
        noWrap: noWrap,
        extraVerticalPadding: extraVerticalPadding,
      );
      final hR = measureTextHeight(
        text: rightTextForItem(i),
        maxWidth: rightWidth,
        style: style,
        textScaler: textScaler,
        noWrap: noWrap,
        extraVerticalPadding: extraVerticalPadding,
      );
      heights[i] = hL > hR ? hL : hR;
    }
    onProgress?.call(end, itemCount);
    await Future<void>.delayed(Duration.zero);
  }
  return LineHeightTable.fromHeights(heights);
}
