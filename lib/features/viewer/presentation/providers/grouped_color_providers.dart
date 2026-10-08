import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/storage/pref_keys.dart';
import 'diff_viewer_providers.dart' show ColorPrefNotifier;

final groupedEqualIgnoringWsBgProvider =
    NotifierProvider<ColorPrefNotifier, Color>(
  () => ColorPrefNotifier(
    key: PrefKeys.colorGroupedEqualIgnoringWsBg,
    initial: const Color(0xFFF7FAFF),
  ),
);

final groupedWsHighlightProvider =
    NotifierProvider<ColorPrefNotifier, Color>(
  () => ColorPrefNotifier(
    key: PrefKeys.colorGroupedWsHighlight,
    initial: const Color(0xFFFFD600),
  ),
);

final groupedFindYellowProvider =
    NotifierProvider<ColorPrefNotifier, Color>(
  () => ColorPrefNotifier(
    key: PrefKeys.colorGroupedFindYellow,
    initial: const Color(0xFFFFF59D),
  ),
);

final groupedFindPinkProvider =
    NotifierProvider<ColorPrefNotifier, Color>(
  () => ColorPrefNotifier(
    key: PrefKeys.colorGroupedFindPink,
    initial: const Color(0xFFFF4081),
  ),
);
