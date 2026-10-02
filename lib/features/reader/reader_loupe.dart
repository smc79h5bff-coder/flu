import 'package:flutter/material.dart';

/// 选区放大镜。只渲染纯文本 + caret 竖线，不掺任何高亮/遮罩。
class ReaderLoupe extends StatelessWidget {
  const ReaderLoupe({
    super.key,
    required this.lineText,
    required this.caretOffset, // caret 在 lineText 里的字符偏移
    required this.style,       // 正文字体样式（只取字号/字重/字距）
    required this.bgColor,     // 放大镜背景（用阅读器同款底色）
    required this.fgColor,     // 文字色
    required this.caretColor,  // 中间竖线色
    this.scale = 1.8,
    this.diameter = 140.0,
    this.windowChars = 40,     // 只截 caret 前后共 40 字符
  });

  final String lineText;
  final int caretOffset;
  final TextStyle style;
  final Color bgColor;
  final Color fgColor;
  final Color caretColor;
  final double scale;
  final double diameter;
  final int windowChars;

  /// 测量用单例，跟 reader_screen 里 _gradTP 一个套路。
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
    final r = diameter / 2;
    final textStyle = style.copyWith(color: fgColor);

    return SizedBox(
      width: diameter,
      height: diameter,
      child: ClipOval(
        child: ColoredBox(
          color: bgColor,
          child: Stack(
            clipBehavior: Clip.hardEdge,
            children: [
              // 文本整体放大后平移，让 caret 精确落在圆心
              Positioned(
                left: r - caretX * scale,
                top: r - lineH * scale / 2,
                child: Transform.scale(
                  scale: scale,
                  alignment: Alignment.topLeft,
                  child: Text(
                    window,
                    style: textStyle,
                    maxLines: 1,
                    softWrap: false,
                    textWidthBasis: TextWidthBasis.longestLine,
                  ),
                ),
              ),
              // caret 竖线（落在圆心，上下留白）
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

// ==================== 测量缓存 ====================

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
