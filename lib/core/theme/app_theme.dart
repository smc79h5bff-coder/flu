import 'package:flutter/material.dart';

import '../constants/app_colors.dart';

/// Light / Dark theme for DocDiff.
/// PRD §4.3: follow system, brand green #6AE8C1, dark bg #121212.
class AppTheme {
  const AppTheme._();

  /// 全局圆角半径。改这一行即可在 6dp / 4dp / 0dp 之间切换。
  static const double radius = 6;

  /// 统一形状：Dialog / PopupMenu / Card / Button / SnackBar / Chip 共用。
  static const RoundedRectangleBorder shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(radius)),
  );

  /// BottomSheet 只做顶部两角（贴底时底部圆角看不见，且顶部圆角更符合 M3）。
  static const RoundedRectangleBorder bottomSheetShape =
      RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(radius)),
      );

  static const BorderRadius radiusAll = BorderRadius.all(
    Radius.circular(radius),
  );

  static ThemeData light() => _build(Brightness.light);

  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final base = ThemeData(brightness: brightness, useMaterial3: true);
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.brandGreen,
      brightness: brightness,
    );
    final isDark = brightness == Brightness.dark;

    return base.copyWith(
      colorScheme: scheme,
      scaffoldBackgroundColor: isDark ? AppColors.darkSurface : Colors.white,
      cardColor: isDark ? AppColors.darkCard : null,

      // —— 动画：平台默认（a1）。
      // 显式钉住是为了 Flutter 升级时默认值不漂移；
      // 若想"完全交给当前版本默认"，把整块 pageTransitionsTheme 删掉即可。
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.linux: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.windows: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.fuchsia: FadeForwardsPageTransitionsBuilder(),
        },
      ),

      // —— 形状：全部引用同一个 shape ——
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: shape,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surface,
        modalBackgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: bottomSheetShape,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: scheme.surface,
        surfaceTintColor: Colors.transparent,
        shape: shape,
      ),
      // Drawer 贴边，不设圆角。
      drawerTheme: DrawerThemeData(
        backgroundColor: scheme.surface,
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: CardThemeData(shape: shape),
      snackBarTheme: SnackBarThemeData(shape: shape),
      chipTheme: ChipThemeData(shape: shape),

      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(shape: shape),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(shape: shape),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(shape: shape),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(shape: shape),
      ),

      // —— 文本：从 colorScheme 派生，不硬编码黑白 ——
      textTheme: base.textTheme.apply(
        bodyColor: scheme.onSurface,
        displayColor: scheme.onSurface,
      ),

      // —— 选中高亮：Diff 工具高频复制 ——
      selectionTheme: SelectionThemeData(
        cursorColor: scheme.primary,
        selectionColor: scheme.primary.withValues(alpha: 0.30),
        selectionHandleColor: scheme.primary,
      ),
    );
  }
}
