import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'diff_viewer_providers.dart';

/// 跨行块视图专属颜色（只在该视图下使用和显示）。
///
/// 复用 diff_viewer_providers.dart 里的 ColorPrefNotifier，
/// 这样设置面板里能直接用现成的 _colorRow 和取色弹窗。

/// 「忽略空白后相同」行的底色（默认浅蓝）
final groupedEqualIgnoringWsBgProvider =
    NotifierProvider<ColorPrefNotifier, Color>(
  () => ColorPrefNotifier(const Color(0xFFF7FAFF)),
);

/// 空白差异高亮（默认橙黄）
final groupedWsHighlightProvider =
    NotifierProvider<ColorPrefNotifier, Color>(
  () => ColorPrefNotifier(const Color(0xFFFFD600)),
);

/// 查找命中底色（默认黄）
final groupedFindYellowProvider =
    NotifierProvider<ColorPrefNotifier, Color>(
  () => ColorPrefNotifier(const Color(0xFFFFF59D)),
);

/// 当前查找命中底色（默认粉）
final groupedFindPinkProvider =
    NotifierProvider<ColorPrefNotifier, Color>(
  () => ColorPrefNotifier(const Color(0xFFFF4081)),
);
