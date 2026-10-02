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
    this.scale = 1.3,
    this.width = 160.0,
    this.height = 56.0,
    this.windowChars = 40,
  });

  final String lineText;
  final int caretOffset;
  final TextStyle style;
  final Color bgColor;
  final Color fgColor;
  final Color caretColor;

  /// 选区在当前行内的起始字符偏移。
  final int? selectionStart;

  /// 选区在当前行内的结束字符偏移。
  final int? selectionEnd;

  final Color selectionBg;

  final double scale;
  final double width;
  final double height;
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
    final cx = width / 2;
    final cy = height / 2;
    final textStyle = style.copyWith(color: fgColor);

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
      width: width,
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: ColoredBox(
          color: bgColor,
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              Positioned(
                left: cx - caretX * scale,
                top: cy - lineH * scale / 2,
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
                left: cx - 0.5,
                top: height * 0.15,
                bottom: height * 0.15,
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
    if (v != null) _m[k] = v;
    return v;
  }

  static void put(String k, _Measure v) {
    if (_m.length >= _cap) _m.remove(_m.keys.first);
    _m[k] = v;
  }
}
