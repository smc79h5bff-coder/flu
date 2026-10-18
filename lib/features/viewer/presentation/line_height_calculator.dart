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
  StrutStyle? strutStyle,   // ★ 新增
}) {
  if (maxWidth <= 0) return 0;
  final effective = text.isEmpty ? ' ' : text;

  _tp.text = TextSpan(text: effective, style: style);
  _tp.textScaler = textScaler;
  _tp.maxLines = noWrap ? 1 : null;
  _tp.ellipsis = noWrap ? '\u2026' : null;
  _tp.strutStyle = strutStyle;   // ★ 每次显式赋值，包括 null，避免残留
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

/// 让出阈值：16ms = 一帧。之前是 4000ms，太大，容易 ANR。
const int _yieldThresholdMs = 16;

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
  // 按行内容去重：同一文本在同一测量参数下高度必然相同，只排一次。
  // 本分支样式/宽度/换行均固定，纯文本即可做 key，测量结果与原来逐位一致。
  final cache = <String, double>{};

  for (var i = 0; i < itemCount; i++) {
    final t = textForItem(i);
    final cached = cache[t];
    if (cached != null) {
      heights[i] = cached;
    } else {
      final h = measureTextHeight(
        text: t,
        maxWidth: w,
        style: style,
        textScaler: textScaler,
        noWrap: false,
        extraVerticalPadding: extraVerticalPadding,
      );
      cache[t] = h;
      heights[i] = h;
    }

    // 每项都检查，超过 16ms 就让出
    if (sw.elapsedMilliseconds >= _yieldThresholdMs) {
      onProgress?.call(i + 1, itemCount);
      await Future<void>.delayed(Duration.zero);
      sw.reset();
    }
  }

  onProgress?.call(itemCount, itemCount);
  return LineHeightTable.fromHeights(heights);
}

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

  if (styleForItem != null || noWrapForItem != null) {
    final heights = List<double>.filled(itemCount, 0);
    final sw = Stopwatch()..start();
    // 样式/换行可能逐项变化，key 用 (文本, 样式, 是否单行) 三元组。
    // record 的 ==/hashCode 基于字段值，样式按值相等去重，安全无碰撞误判。
    final cacheL = <(String, TextStyle, bool), double>{};
    final cacheR = <(String, TextStyle, bool), double>{};

    double measureL(String t, TextStyle s, bool nw) {
      final key = (t, s, nw);
      final v = cacheL[key];
      if (v != null) return v;
      final h = measureTextHeight(
        text: t,
        maxWidth: leftWidth,
        style: s,
        textScaler: textScaler,
        noWrap: nw,
        extraVerticalPadding: extraVerticalPadding,
      );
      cacheL[key] = h;
      return h;
    }

    double measureR(String t, TextStyle s, bool nw) {
      final key = (t, s, nw);
      final v = cacheR[key];
      if (v != null) return v;
      final h = measureTextHeight(
        text: t,
        maxWidth: rightWidth,
        style: s,
        textScaler: textScaler,
        noWrap: nw,
        extraVerticalPadding: extraVerticalPadding,
      );
      cacheR[key] = h;
      return h;
    }

    for (var i = 0; i < itemCount; i++) {
      final s = styleForItem?.call(i) ?? style;
      final nw = noWrapForItem?.call(i) ?? noWrap;
      final lt = leftTextForItem(i);
      final rt = rightTextForItem(i);

      if (nw) {
        final hL = measureL(lt, s, true);
        final hR = measureR(rt, s, true);
        heights[i] = hL > hR ? hL : hR;
      } else if (lt == rt) {
        heights[i] = measureL(lt, s, false);
      } else {
        final hL = measureL(lt, s, false);
        final hR = measureR(rt, s, false);
        heights[i] = hL > hR ? hL : hR;
      }

      if (sw.elapsedMilliseconds >= _yieldThresholdMs) {
        onProgress?.call(i + 1, itemCount);
        await Future<void>.delayed(Duration.zero);
        sw.reset();
      }
    }
    onProgress?.call(itemCount, itemCount);
    return LineHeightTable.fromHeights(heights);
  }

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
  // 样式/宽度固定，直接按文本去重（左右各一张表）。
  final cacheL = <String, double>{};
  final cacheR = <String, double>{};

  double measureL(String t) {
    final v = cacheL[t];
    if (v != null) return v;
    final h = measureTextHeight(
      text: t,
      maxWidth: leftWidth,
      style: style,
      textScaler: textScaler,
      noWrap: false,
      extraVerticalPadding: extraVerticalPadding,
    );
    cacheL[t] = h;
    return h;
  }

  double measureR(String t) {
    final v = cacheR[t];
    if (v != null) return v;
    final h = measureTextHeight(
      text: t,
      maxWidth: rightWidth,
      style: style,
      textScaler: textScaler,
      noWrap: false,
      extraVerticalPadding: extraVerticalPadding,
    );
    cacheR[t] = h;
    return h;
  }

  for (var i = 0; i < itemCount; i++) {
    final lt = leftTextForItem(i);
    final rt = rightTextForItem(i);

    if (lt == rt) {
      heights[i] = measureL(lt);
    } else {
      final hL = measureL(lt);
      final hR = measureR(rt);
      heights[i] = hL > hR ? hL : hR;
    }

    if (sw.elapsedMilliseconds >= _yieldThresholdMs) {
      onProgress?.call(i + 1, itemCount);
      await Future<void>.delayed(Duration.zero);
      sw.reset();
    }
  }

  onProgress?.call(itemCount, itemCount);
  return LineHeightTable.fromHeights(heights);
}
