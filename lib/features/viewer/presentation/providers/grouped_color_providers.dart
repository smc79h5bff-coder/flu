import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 跨行块视图专属颜色（仅在该视图下使用与显示）。

/// 「忽略空白后相同」行的底色（默认浅蓝）
final groupedEqualIgnoringWsBgProvider =
    StateProvider<Color>((ref) => const Color(0xFFF7FAFF));

/// 空白差异高亮（默认橙黄）
final groupedWsHighlightProvider =
    StateProvider<Color>((ref) => const Color(0xFFFFD600));

/// 查找命中底色（默认黄）
final groupedFindYellowProvider =
    StateProvider<Color>((ref) => const Color(0xFFFFF59D));

/// 当前查找命中底色（默认粉）
final groupedFindPinkProvider =
    StateProvider<Color>((ref) => const Color(0xFFFF4081));
