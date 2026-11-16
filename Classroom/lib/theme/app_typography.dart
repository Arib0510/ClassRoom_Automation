import 'package:flutter/material.dart';
import 'app_colors.dart';

/// Type scale. Two families, both bundled with the app (see `pubspec.yaml`)
/// so text renders identically offline and never reflows after a late font
/// download:
///
///  * Space Grotesk — headlines and large numerals.
///  * Inter — body copy and UI labels.
///
/// A colour left unset resolves against the active palette at call time.
class AppTypography {
  AppTypography._();

  static const String headlineFamily = 'SpaceGrotesk';
  static const String bodyFamily = 'Inter';

  static TextStyle _style({
    required String family,
    required double size,
    required FontWeight weight,
    required Color color,
    double letterSpacing = 0,
    double height = 1.3,
  }) {
    return TextStyle(
      fontFamily: family,
      fontSize: size,
      fontWeight: weight,
      letterSpacing: letterSpacing,
      height: height,
      // Centre glyphs in their line box so text sits optically centred in
      // chips, pills and buttons instead of riding high.
      leadingDistribution: TextLeadingDistribution.even,
      color: color,
    );
  }

  // --- Headlines: Space Grotesk ---

  static TextStyle displayLg({
    Color? color,
    double? fontSize,
    FontWeight? fontWeight,
  }) {
    final size = fontSize ?? 38;
    return _style(
      family: headlineFamily,
      size: size,
      weight: fontWeight ?? FontWeight.w700,
      letterSpacing: -0.02 * size,
      height: 1.15,
      color: color ?? AppColors.onSurface,
    );
  }

  static TextStyle headlineLg({
    Color? color,
    double? fontSize,
    FontWeight? fontWeight,
  }) {
    final size = fontSize ?? 26;
    return _style(
      family: headlineFamily,
      size: size,
      weight: fontWeight ?? FontWeight.w600,
      letterSpacing: -0.01 * size,
      height: 1.2,
      color: color ?? AppColors.onSurface,
    );
  }

  static TextStyle headlineMd({
    Color? color,
    double? fontSize,
    FontWeight? fontWeight,
  }) {
    final size = fontSize ?? 20;
    return _style(
      family: headlineFamily,
      size: size,
      weight: fontWeight ?? FontWeight.w600,
      letterSpacing: -0.01 * size,
      height: 1.25,
      color: color ?? AppColors.onSurface,
    );
  }

  static TextStyle headlineSm({
    Color? color,
    double? fontSize,
    FontWeight? fontWeight,
  }) {
    return _style(
      family: headlineFamily,
      size: fontSize ?? 16,
      weight: fontWeight ?? FontWeight.w500,
      height: 1.25,
      color: color ?? AppColors.onSurface,
    );
  }

  // --- Body: Inter ---

  static TextStyle bodyLg({
    Color? color,
    double? fontSize,
    FontWeight? fontWeight,
  }) {
    return _style(
      family: bodyFamily,
      size: fontSize ?? 16,
      weight: fontWeight ?? FontWeight.w400,
      height: 1.4,
      color: color ?? AppColors.onSurface,
    );
  }

  static TextStyle bodyMd({
    Color? color,
    double? fontSize,
    FontWeight? fontWeight,
  }) {
    return _style(
      family: bodyFamily,
      size: fontSize ?? 14,
      weight: fontWeight ?? FontWeight.w400,
      height: 1.4,
      color: color ?? AppColors.onSurface,
    );
  }

  static TextStyle bodySm({
    Color? color,
    double? fontSize,
    FontWeight? fontWeight,
  }) {
    return _style(
      family: bodyFamily,
      size: fontSize ?? 12,
      weight: fontWeight ?? FontWeight.w400,
      height: 1.4,
      color: color ?? AppColors.onSurfaceVariant,
    );
  }

  // --- Labels: Inter, semi-bold, lightly tracked ---

  static TextStyle labelLg({
    Color? color,
    double? fontSize,
    FontWeight? fontWeight,
  }) {
    return _style(
      family: bodyFamily,
      size: fontSize ?? 13,
      weight: fontWeight ?? FontWeight.w600,
      letterSpacing: 0.15,
      height: 1.25,
      color: color ?? AppColors.primary,
    );
  }

  static TextStyle labelMd({
    Color? color,
    double? fontSize,
    FontWeight? fontWeight,
  }) {
    return _style(
      family: bodyFamily,
      size: fontSize ?? 12,
      weight: fontWeight ?? FontWeight.w600,
      letterSpacing: 0.2,
      height: 1.25,
      color: color ?? AppColors.onSurfaceVariant,
    );
  }

  static TextStyle labelSm({
    Color? color,
    double? fontSize,
    FontWeight? fontWeight,
  }) {
    return _style(
      family: bodyFamily,
      size: fontSize ?? 11,
      weight: fontWeight ?? FontWeight.w600,
      letterSpacing: 0.25,
      height: 1.25,
      color: color ?? AppColors.onSurfaceVariant,
    );
  }
}
