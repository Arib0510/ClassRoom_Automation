import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'app_colors.dart';

class AppTypography {
  // Headlines: Space Grotesk
  static TextStyle displayLg({
    Color color = AppColors.onSurface,
    double? fontSize,
    FontWeight? fontWeight,
  }) {
    return GoogleFonts.spaceGrotesk(
      fontSize: fontSize ?? 38,
      fontWeight: fontWeight ?? FontWeight.w700,
      letterSpacing: -0.02 * (fontSize ?? 38),
      color: color,
    );
  }

  static TextStyle headlineLg({
    Color color = AppColors.onSurface,
    double? fontSize,
    FontWeight? fontWeight,
  }) {
    return GoogleFonts.spaceGrotesk(
      fontSize: fontSize ?? 26,
      fontWeight: fontWeight ?? FontWeight.w600,
      letterSpacing: -0.01 * (fontSize ?? 26),
      color: color,
    );
  }

  static TextStyle headlineMd({
    Color color = AppColors.onSurface,
    double? fontSize,
    FontWeight? fontWeight,
  }) {
    return GoogleFonts.spaceGrotesk(
      fontSize: fontSize ?? 20,
      fontWeight: fontWeight ?? FontWeight.w600,
      letterSpacing: -0.01 * (fontSize ?? 20),
      color: color,
    );
  }

  static TextStyle headlineSm({
    Color color = AppColors.onSurface,
    double? fontSize,
    FontWeight? fontWeight,
  }) {
    return GoogleFonts.spaceGrotesk(
      fontSize: fontSize ?? 16,
      fontWeight: fontWeight ?? FontWeight.w500,
      color: color,
    );
  }

  // Body: Geist / Inter fallback
  static TextStyle bodyLg({
    Color color = AppColors.onSurface,
    double? fontSize,
    FontWeight? fontWeight,
  }) {
    return GoogleFonts.inter(
      fontSize: fontSize ?? 16,
      fontWeight: fontWeight ?? FontWeight.w400,
      color: color,
    );
  }

  static TextStyle bodyMd({
    Color color = AppColors.onSurface,
    double? fontSize,
    FontWeight? fontWeight,
  }) {
    return GoogleFonts.inter(
      fontSize: fontSize ?? 14,
      fontWeight: fontWeight ?? FontWeight.w400,
      color: color,
    );
  }

  static TextStyle bodySm({
    Color color = AppColors.onSurfaceVariant,
    double? fontSize,
    FontWeight? fontWeight,
  }) {
    return GoogleFonts.inter(
      fontSize: fontSize ?? 12,
      fontWeight: fontWeight ?? FontWeight.w400,
      color: color,
    );
  }

  // Telemetry & Technical: JetBrains Mono
  static TextStyle labelLg({
    Color color = AppColors.primary,
    double? fontSize,
    FontWeight? fontWeight,
  }) {
    return GoogleFonts.jetBrainsMono(
      fontSize: fontSize ?? 13,
      fontWeight: fontWeight ?? FontWeight.w600,
      letterSpacing: 0.04 * (fontSize ?? 13),
      color: color,
    );
  }

  static TextStyle labelMd({
    Color color = AppColors.onSurfaceVariant,
    double? fontSize,
    FontWeight? fontWeight,
  }) {
    return GoogleFonts.jetBrainsMono(
      fontSize: fontSize ?? 11,
      fontWeight: fontWeight ?? FontWeight.w500,
      letterSpacing: 0.06 * (fontSize ?? 11),
      color: color,
    );
  }

  static TextStyle labelSm({
    Color color = AppColors.onSurfaceVariant,
    double? fontSize,
    FontWeight? fontWeight,
  }) {
    return GoogleFonts.jetBrainsMono(
      fontSize: fontSize ?? 10,
      fontWeight: fontWeight ?? FontWeight.w500,
      letterSpacing: 0.08 * (fontSize ?? 10),
      color: color,
    );
  }
}
