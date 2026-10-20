import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../constants/app_colors.dart';
import '../storage/persistent_notifier.dart';
import '../storage/pref_keys.dart';
import 'app_theme.dart';

/// 可选皮肤。
///
/// `grayPurple` 是默认皮肤，直接用手搓的 AppColors.lightScheme / darkScheme；
/// 其余皮肤用 [seed] 通过 ColorScheme.fromSeed 生成。
enum AppSkin {
  grayPurple('灰紫', Color(0xFF6B5A7E)),
  pink('粉', Color(0xFFE91E63)),
  orange('橙', Color(0xFFE65100)),
  yellow('黄', Color(0xFFF9A825)),
  green('绿', Color(0xFF2E7D32)),
  teal('青', Color(0xFF00897B)),
  blue('蓝', Color(0xFF1565C0));

  final String label;
  final Color seed;
  const AppSkin(this.label, this.seed);
}

class SkinNotifier extends EnumPrefNotifier<AppSkin> {
  SkinNotifier()
      : super(
          key: PrefKeys.skin,
          values: AppSkin.values,
          initial: AppSkin.grayPurple,
        );
}

final skinProvider =
    NotifierProvider<SkinNotifier, AppSkin>(SkinNotifier.new);

ColorScheme _lightOf(AppSkin skin) => skin == AppSkin.grayPurple
    ? AppColors.lightScheme
    : ColorScheme.fromSeed(seedColor: skin.seed);

ColorScheme _darkOf(AppSkin skin) => skin == AppSkin.grayPurple
    ? AppColors.darkScheme
    : ColorScheme.fromSeed(
        seedColor: skin.seed,
        brightness: Brightness.dark,
      );

ThemeData lightThemeOf(AppSkin skin) => AppTheme.light(_lightOf(skin));
ThemeData darkThemeOf(AppSkin skin) => AppTheme.dark(_darkOf(skin));
