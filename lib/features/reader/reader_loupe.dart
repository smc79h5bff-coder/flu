import 'package:flutter/material.dart';

/// 选区放大镜。只渲染纯文本 + caret 竖线 + 选区背景，不掺其他高亮/遮罩。
class ReaderLoupe extends StatelessWidget {
  const ReaderLoupe({
    super.key,
    required this.lineText,
    required this.caretOffset,
    required this.style,
    required this.bgColor,
    required this.fgColor,
    required this.caretColor,
    this.selectionStart,
    this.selectionEnd,
    this.selectionBg = const Color(0x773D7CFF),
    this.scale = 1.8,
    this.diameter = 140.0,
    this.windowChars = 40,
  });

  final String lineText;
  final int caretOffset;
  final TextStyle style;
  final Color bgColor;
  final Color fgColor;
  final Color caretColor;

  /// 选区在当前行内的起始字符偏移（相对整行 lineText）。
  /// 和 [selectionEnd] 一起决定窗口内哪段文字带选中背景。
  /// 都传 null 或相同值 → 不画选中背景。
  final int? selectionStart;
  final int? selectionEnd;

  /// 选中背景色。默认跟阅读页选区一致。
  final Color selectionBg;

  final double scale;
  final double diameter;
  final int windowChars;

  static final TextPainter _tp = TextPainter(
    textDirection: TextDirection.ltr,
    textAlign: TextAlign.left,
    locale: const Locale('zh', 'CN'),
  );

  @override
  Widget build(BuildContext context) {
    // ---- 1. 截窗口 ----
    final n = lineText.length;
    final half = windowChars ~/ 2;
    final left = (caretOffset - half).clamp(0, n);
    final right = (caretOffset + half).clamp(0, n);
    final window = lineText.substring(left, right);
    final windowCaret = caretOffset - left;

    // 选区在 window 内的相对位置（如果和 window 有重叠）
    int? selA;
    int? selB;
    if (selectionStart != null && selectionEnd != null) {
      final sFull = selectionStart!.clamp(left, right);
      final eFull = selectionEnd!.clamp(left, right);
      if (eFull > sFull) {
        selA = sFull - left;
        selB = eFull - left;
      }
    }

    // ---- 2. 测量 caret x（带 LRU 缓存）----
    // 测量时用纯 style，不含选区背景色，保证 caret x 精确。
    final key = '${window.hashCode}|$windowCaret|'
        '${style.fontSize}|${style.fontWeight?.index}|'
        '${style.letterSpacing}|${style.wordSpacing}';
    final hit = _MeasureCache.get(key);
    final double caretX;
    final double lineH;
    if (hit != null) {
      caretX = hit.caretX;
      lineH = hit.lineH;
    } else {
      final tp = _tp;
      tp.text = TextSpan(text: window, style: style);
      tp.layout();
      final p = tp.getOffsetForCaret(
        TextPosition(offset: windowCaret),
        Rect.zero,
      );
      caretX = p.dx;
      lineH = tp.height;
      _MeasureCache.put(key, _Measure(caretX, lineH));
    }

    // ---- 3. 渲染 ----
    final r = diameter / 2;
    final textStyle = style.copyWith(color: fgColor);

    // 构建文本（如有选区，用 TextSpan 分段加背景）
    final InlineSpan span;
    if (selA != null && selB != null) {
      final before = window.substring(0, selA);
      final mid = window.substring(selA, selB);
      final after = window.substring(selB);
      span = TextSpan(
        style: textStyle,
        children: [
          if (before.isNotEmpty) TextSpan(text: before),
          if (mid.isNotEmpty)
            TextSpan(
              text: mid,
              style: TextStyle(backgroundColor: selectionBg),
            ),
          if (after.isNotEmpty) TextSpan(text: after),
        ],
      );
    } else {
      span = TextSpan(text: window, style: textStyle);
    }

    return SizedBox(
      width: diameter,
      height: diameter,
      child: ClipOval(
        child: ColoredBox(
          color: bgColor,
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              Positioned(
                left: r - caretX * scale,
                top: r - lineH * scale / 2,
                child: Transform.scale(
                  scale: scale,
                  alignment: Alignment.topLeft,
                  child: Text.rich(
                    span,
                    maxLines: 1,
                    softWrap: false,
                    textWidthBasis: TextWidthBasis.longestLine,
                  ),
                ),
              ),
              Positioned(
                left: r - 0.5,
                top: diameter * 0.15,
                bottom: diameter * 0.15,
                width: 1,
                child: ColoredBox(color: caretColor),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Measure {
  const _Measure(this.caretX, this.lineH);
  final double caretX;
  final double lineH;
}

class _MeasureCache {
  static const int _cap = 256;
  static final Map<String, _Measure> _m = {};

  static _Measure? get(String k) {
    final v = _m.remove(k);
    if (v != null) _m[k] = v; // LRU 提升
    return v;
  }

  static void put(String k, _Measure v) {
    if (_m.length >= _cap) _m.remove(_m.keys.first);
    _m[k] = v;
  }
}
