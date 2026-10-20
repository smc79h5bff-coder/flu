import 'package:flutter/material.dart';

/// PRD §5: visualization highlights.
/// Light and dark variants per category.
class AppColors {
  const AppColors._();

  // Diff highlights — light mode
  static const Color addedLight = Color(0xFF2ECC71);
  static const Color deletedLight = Color(0xFFE74C3C);
  static const Color modifiedLight = Color(0xFFF1C40F);

  // Diff highlights — dark mode (PRD §5)
  static const Color addedDark = Color(0xFF3DDC84);
  static const Color deletedDark = Color(0xFFFF6B6B);
  static const Color modifiedDark = Color(0xFFFFD60A);

  static Color addedOf(BuildContext c) =>
      Theme.of(c).brightness == Brightness.dark ? addedDark : addedLight;
  static Color deletedOf(BuildContext c) =>
      Theme.of(c).brightness == Brightness.dark ? deletedDark : deletedLight;
  static Color modifiedOf(BuildContext c) =>
      Theme.of(c).brightness == Brightness.dark ? modifiedDark : modifiedLight;

  // ---------------------------------------------------------------
  // 浅色主题：主色是灰紫，其余全部纯灰（R=G=B）
  // ---------------------------------------------------------------
  static const ColorScheme lightScheme = ColorScheme(
    brightness: Brightness.light,

    // —— 主色（按钮、选中态用它）——
    primary: Color(0xFF6B5A7E),
    onPrimary: Color(0xFFFFFFFF),
    primaryContainer: Color(0xFFEDE5F4),
    onPrimaryContainer: Color(0xFF2A2138),

    // —— 次要色：同色系更灰一点 ——
    secondary: Color(0xFF7A7285),
    onSecondary: Color(0xFFFFFFFF),
    secondaryContainer: Color(0xFFE8E4ED),
    onSecondaryContainer: Color(0xFF25222B),

    tertiary: Color(0xFF616161),
    onTertiary: Color(0xFFFFFFFF),
    tertiaryContainer: Color(0xFFE0E0E0),
    onTertiaryContainer: Color(0xFF1C1C1C),

    error: Color(0xFFB3261E),
    onError: Color(0xFFFFFFFF),
    errorContainer: Color(0xFFF9DEDC),
    onErrorContainer: Color(0xFF410E0B),

    // —— 背景：纯灰 ——
    surface: Color(0xFFFAFAFA),
    onSurface: Color(0xFF1C1C1C),
    surfaceDim: Color(0xFFE0E0E0),
    surfaceBright: Color(0xFFFAFAFA),
    surfaceContainerLowest: Color(0xFFFFFFFF),
    surfaceContainerLow: Color(0xFFF5F5F5),
    surfaceContainer: Color(0xFFEEEEEE),
    surfaceContainerHigh: Color(0xFFE8E8E8),
    surfaceContainerHighest: Color(0xFFE0E0E0),
    onSurfaceVariant: Color(0xFF616161),

    outline: Color(0xFF9E9E9E),
    outlineVariant: Color(0xFFE0E0E0),

    // 透明，防止组件把背景染偏色
    surfaceTint: Color(0x00000000),

    inverseSurface: Color(0xFF303030),
    onInverseSurface: Color(0xFFF5F5F5),
    inversePrimary: Color(0xFFD5C4E8),

    shadow: Color(0xFF000000),
    scrim: Color(0xFF000000),
  );

  // ---------------------------------------------------------------
  // 夜间主题：主色是浅灰紫，其余纯灰
  // ---------------------------------------------------------------
  static const ColorScheme darkScheme = ColorScheme(
    brightness: Brightness.dark,

    // —— 主色 ——
    primary: Color(0xFFCBB9DD),
    onPrimary: Color(0xFF352A44),
    primaryContainer: Color(0xFF4A3D5C),
    onPrimaryContainer: Color(0xFFE9DEF5),

    secondary: Color(0xFFB0A6BC),
    onSecondary: Color(0xFF2B2733),
    secondaryContainer: Color(0xFF423C4C),
    onSecondaryContainer: Color(0xFFE5DFEA),

    tertiary: Color(0xFFBDBDBD),
    onTertiary: Color(0xFF1C1C1C),
    tertiaryContainer: Color(0xFF424242),
    onTertiaryContainer: Color(0xFFE0E0E0),

    error: Color(0xFFFFB4AB),
    onError: Color(0xFF690005),
    errorContainer: Color(0xFF93000A),
    onErrorContainer: Color(0xFFFFDAD6),

    // —— 背景：纯灰 ——
    surface: Color(0xFF121212),
    onSurface: Color(0xFFE0E0E0),
    surfaceDim: Color(0xFF121212),
    surfaceBright: Color(0xFF424242),
    surfaceContainerLowest: Color(0xFF0A0A0A),
    surfaceContainerLow: Color(0xFF1A1A1A),
    surfaceContainer: Color(0xFF1E1E1E),
    surfaceContainerHigh: Color(0xFF262626),
    surfaceContainerHighest: Color(0xFF303030),
    onSurfaceVariant: Color(0xFFBDBDBD),

    outline: Color(0xFF757575),
    outlineVariant: Color(0xFF424242),

    surfaceTint: Color(0x00000000),

    inverseSurface: Color(0xFFE0E0E0),
    onInverseSurface: Color(0xFF1C1C1C),
    inversePrimary: Color(0xFF6B5A7E),

    shadow: Color(0xFF000000),
    scrim: Color(0xFF000000),
  );
}
