import 'package:flutter/material.dart';

/// PRD §5: visualization highlights.
/// Light and dark variants per category.
class AppColors {
  const AppColors._();

  static const Color brandGreen = Color(0xFFFFF5F6);

  // Diff highlights — light mode
  static const Color addedLight = Color(0xFF2ECC71);
  static const Color deletedLight = Color(0xFFE74C3C);
  static const Color modifiedLight = Color(0xFFF1C40F);

  // Diff highlights — dark mode (PRD §5)
  static const Color addedDark = Color(0xFF3DDC84);
  static const Color deletedDark = Color(0xFFFF6B6B);
  static const Color modifiedDark = Color(0xFFFFD60A);

  // Surfaces
  static const Color darkSurface = Color(0xFF121212);
  static const Color darkCard = Color(0xFF1E1E1E);
  static const Color darkText = Color(0xFFE0E0E0);

  static Color addedOf(BuildContext c) =>
      Theme.of(c).brightness == Brightness.dark ? addedDark : addedLight;
  static Color deletedOf(BuildContext c) =>
      Theme.of(c).brightness == Brightness.dark ? deletedDark : deletedLight;
  static Color modifiedOf(BuildContext c) =>
      Theme.of(c).brightness == Brightness.dark ? modifiedDark : modifiedLight;
}
