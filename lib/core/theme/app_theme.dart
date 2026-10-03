static ThemeData light() {
  final base = ThemeData.light(useMaterial3: true);

  final colorScheme = ColorScheme.fromSeed(
    seedColor: AppColors.brandGreen,
    brightness: Brightness.light,
  ).copyWith(
    surface: Colors.white,
    surfaceTint: Colors.transparent,
    surfaceContainerLowest: Colors.white,
    surfaceContainerLow: Colors.white,
    surfaceContainer: Colors.white,
    surfaceContainerHigh: Colors.white,
    surfaceContainerHighest: Colors.white,
  );

  return base.copyWith(
    colorScheme: colorScheme,
    scaffoldBackgroundColor: Colors.white,
    canvasColor: Colors.white,
    cardColor: Colors.white,

    dialogTheme: const DialogThemeData(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
    ),
    bottomSheetTheme: const BottomSheetThemeData(
      backgroundColor: Colors.white,
      modalBackgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
    ),
    popupMenuTheme: const PopupMenuThemeData(
      color: Colors.white,
      surfaceTintColor: Colors.transparent,
    ),
    drawerTheme: const DrawerThemeData(
      backgroundColor: Colors.white,
      surfaceTintColor: Colors.transparent,
    ),
  );
}
