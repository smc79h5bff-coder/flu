import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/storage/pref_keys.dart';
import 'diff_viewer_providers.dart' show ColorPrefNotifier;

/// 跨行块视图专属颜色（仅在该视图下使用与显示）。

/// 「忽略空白后相同」的整块底色（默认浅蓝）
final groupedEqualIgnoringWsBgProvider =
    NotifierProvider<ColorPrefNotifier, Color>(
  () => ColorPrefNotifier(
    key: PrefKeys.colorGroupedEqualIgnoringWsBg,
    initial: const Color(0xFFF7FAFF),
  ),
);

/// 空白差异高亮（默认橙黄）
final groupedWsHighlightProvider =
    NotifierProvider<ColorPrefNotifier, Color>(
  () => ColorPrefNotifier(
    key: PrefKeys.colorGroupedWsHighlight,
    initial: const Color(0xFFFFD600),
  ),
);

/// 查找命中底色（默认黄）
final groupedFindYellowProvider =
    NotifierProvider<ColorPrefNotifier, Color>(
  () => ColorPrefNotifier(
    key: PrefKeys.colorGroupedFindYellow,
    initial: const Color(0xFFFFF59D),
  ),
);

/// 当前查找命中底色（默认粉）
final groupedFindPinkProvider =
    NotifierProvider<ColorPrefNotifier, Color>(
  () => ColorPrefNotifier(
    key: PrefKeys.colorGroupedFindPink,
    initial: const Color(0xFFFF4081),
  ),
);
