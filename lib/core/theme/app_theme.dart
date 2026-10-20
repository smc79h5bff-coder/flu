import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';

import '../constants/app_colors.dart';

/// Light / Dark theme for DocDiff.
/// 主体色板由调用方通过 [scheme] 参数传入
/// （默认皮肤用 AppColors.lightScheme / darkScheme，
///  其他皮肤用 ColorScheme.fromSeed 生成）。
/// 弹窗 / 菜单 / 底部弹窗 / AppBar / 卡片一律强制白色（深色用 darkCard），
/// 不再从 scheme.surface 取，避免 M3 叠加 tint 后泛蓝。
class AppTheme {
  const AppTheme._();

  static const double radius = 6;

  static const RoundedRectangleBorder shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(radius)),
  );

  static const double buttonRadius = 18;

  static const RoundedRectangleBorder buttonShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(buttonRadius)),
  );

  static const RoundedRectangleBorder bottomSheetShape =
      RoundedRectangleBorder(
    borderRadius: BorderRadius.vertical(top: Radius.circular(radius)),
  );

  static const BorderRadius radiusAll = BorderRadius.all(
    Radius.circular(radius),
  );

  static ThemeData light(ColorScheme scheme) =>
      _build(Brightness.light, scheme);

  static ThemeData dark(ColorScheme scheme) =>
      _build(Brightness.dark, scheme);

  static ThemeData _build(Brightness brightness, ColorScheme scheme) {
    final base = ThemeData(brightness: brightness, useMaterial3: true);
    final isDark = brightness == Brightness.dark;

    // ★ 弹窗类统一底色：浅色纯白、深色深灰。
    //   这个不跟 scheme.surface 走，就是为了防止某个色板调色时
    //   弹窗跟着泛蓝。
    final popupBg = isDark ? AppColors.darkCard : Colors.white;
    final pageBg = isDark ? AppColors.darkSurface : Colors.white;

    return base.copyWith(
      colorScheme: scheme,

      // 兼容遗留组件读 primaryColor / canvasColor。
      primaryColor: scheme.primary,
      canvasColor: pageBg,

      scaffoldBackgroundColor: pageBg,
      cardColor: isDark ? AppColors.darkCard : Colors.white,

      dividerColor: scheme.outlineVariant,
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),

      // ★ AppBar：白底、黑字（深色：深底、浅字），去掉 tint。
      appBarTheme: AppBarTheme(
        backgroundColor: pageBg,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
        iconTheme: IconThemeData(color: scheme.onSurface),
      ),

      // —— 动画 ——
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

      // ★ 所有弹窗类背景统一白（深色 darkCard）。
      dialogTheme: DialogThemeData(
        backgroundColor: popupBg,
        surfaceTintColor: Colors.transparent,
        shape: shape,
        titleTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
        contentTextStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 14,
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: popupBg,
        modalBackgroundColor: popupBg,
        surfaceTintColor: Colors.transparent,
        shape: bottomSheetShape,
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: popupBg,
        surfaceTintColor: Colors.transparent,
        shape: shape,
        textStyle: TextStyle(
          color: scheme.onSurface,
          fontSize: 14,
        ),
      ),
      drawerTheme: DrawerThemeData(
        backgroundColor: popupBg,
        surfaceTintColor: Colors.transparent,
      ),
      // 卡片也顺便定白，否则部分列表会把 Card 默认色带蓝。
      cardTheme: CardThemeData(
        shape: shape,
        color: isDark ? AppColors.darkCard : Colors.white,
        surfaceTintColor: Colors.transparent,
      ),
      snackBarTheme: SnackBarThemeData(shape: shape),
      chipTheme: ChipThemeData(shape: shape),

      // —— 按钮 ——
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(shape: buttonShape),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(shape: buttonShape),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(shape: buttonShape),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(shape: buttonShape),
      ),

      // —— 文本 ——
      textTheme: base.textTheme.apply(
        bodyColor: scheme.onSurface,
        displayColor: scheme.onSurface,
      ),

      // —— 光标 / 选中 ——
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: scheme.primary,
        selectionColor: scheme.primary.withValues(alpha: 0.30),
        selectionHandleColor: scheme.primary,
      ),
    );
  }
}
