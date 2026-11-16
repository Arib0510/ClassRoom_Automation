import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'app_colors.dart';
import 'app_typography.dart';

/// Material themes built from [AppPalette], so stock Material widgets
/// (dialogs, text fields, menus, snack bars, switches) match the custom ones.
class AppTheme {
  AppTheme._();

  static ThemeData get darkTheme => _build(AppPalette.dark);
  static ThemeData get lightTheme => _build(AppPalette.light);

  /// System status/navigation bar styling for the given palette.
  static SystemUiOverlayStyle overlayStyle(AppPalette p) {
    final isDark = p.brightness == Brightness.dark;
    final iconBrightness = isDark ? Brightness.light : Brightness.dark;
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: iconBrightness,
      statusBarBrightness: p.brightness,
      systemNavigationBarColor: p.surfaceContainerLowest,
      systemNavigationBarIconBrightness: iconBrightness,
      systemNavigationBarDividerColor: Colors.transparent,
    );
  }

  static ThemeData _build(AppPalette p) {
    final isDark = p.brightness == Brightness.dark;
    final hairline = p.overlayBase
        .withValues(alpha: (0.10 * p.overlayScale).clamp(0.0, 1.0));

    TextStyle text(
      String family,
      double size,
      FontWeight weight,
      Color color, {
      double height = 1.35,
    }) {
      return TextStyle(
        fontFamily: family,
        fontSize: size,
        fontWeight: weight,
        height: height,
        leadingDistribution: TextLeadingDistribution.even,
        color: color,
      );
    }

    const head = AppTypography.headlineFamily;
    const body = AppTypography.bodyFamily;

    final scheme = ColorScheme(
      brightness: p.brightness,
      primary: p.primary,
      onPrimary: p.onPrimary,
      primaryContainer: p.primaryContainer,
      onPrimaryContainer: p.onPrimary,
      secondary: p.secondary,
      onSecondary: p.onSecondary,
      tertiary: p.tertiaryContainer,
      onTertiary: p.onTertiary,
      error: p.criticalRed,
      onError: p.onError,
      errorContainer: p.errorContainer,
      surface: p.surface,
      onSurface: p.onSurface,
      onSurfaceVariant: p.onSurfaceVariant,
      outline: p.outline,
      outlineVariant: p.outlineVariant,
      surfaceContainerLowest: p.surfaceContainerLowest,
      surfaceContainerLow: p.surfaceContainerLow,
      surfaceContainer: p.surfaceContainer,
      surfaceContainerHigh: p.surfaceContainerHigh,
      surfaceContainerHighest: p.surfaceContainerHighest,
      surfaceTint: Colors.transparent,
      shadow: p.shadowBase,
      scrim: Colors.black,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: p.brightness,
      fontFamily: body,
      scaffoldBackgroundColor: p.surfaceContainerLowest,
      canvasColor: p.surfaceContainerLowest,
      primaryColor: p.primary,
      colorScheme: scheme,
      dividerColor: hairline,
      splashFactory: InkSparkle.splashFactory,
      appBarTheme: AppBarTheme(
        backgroundColor: p.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        foregroundColor: p.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        titleTextStyle: text(head, 17, FontWeight.w600, p.onSurface),
        iconTheme: IconThemeData(color: p.onSurface),
        systemOverlayStyle: overlayStyle(p),
      ),
      cardTheme: CardThemeData(
        color: p.surfaceContainerLow,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: hairline, width: 1),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: p.sheet,
        surfaceTintColor: Colors.transparent,
        elevation: isDark ? 0 : 12,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: hairline),
        ),
        titleTextStyle: text(head, 18, FontWeight.w600, p.onSurface),
        contentTextStyle: text(body, 14, FontWeight.w400, p.onSurfaceVariant),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: p.sheet,
        surfaceTintColor: Colors.transparent,
        modalBackgroundColor: p.sheet,
        modalBarrierColor:
            isDark ? const Color(0xB8000000) : const Color(0x7A101828),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: p.sheet,
        surfaceTintColor: Colors.transparent,
        elevation: isDark ? 4 : 10,
        shadowColor: p.shadowBase.withValues(alpha: isDark ? 0.6 : 0.2),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: hairline),
        ),
        textStyle: text(body, 13.5, FontWeight.w500, p.onSurface),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: isDark ? const Color(0xFF243044) : const Color(0xFF1D2939),
        contentTextStyle: text(body, 13.5, FontWeight.w500, Colors.white),
        actionTextColor: AppPalette.dark.primary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        behavior: SnackBarBehavior.floating,
        elevation: 6,
      ),
      inputDecorationTheme: InputDecorationTheme(
        labelStyle: text(body, 13.5, FontWeight.w400, p.onSurfaceVariant),
        hintStyle: text(body, 13.5, FontWeight.w400, p.outline),
        floatingLabelStyle: text(body, 13.5, FontWeight.w600, p.primary),
        helperStyle: text(body, 11.5, FontWeight.w400, p.outline),
        errorStyle: text(body, 11.5, FontWeight.w500, p.criticalRed),
        prefixIconColor: p.outline,
        suffixIconColor: p.outline,
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: p.primary,
        selectionColor: p.primary.withValues(alpha: 0.28),
        selectionHandleColor: p.primary,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: p.primary,
          foregroundColor: p.onPrimary,
          disabledBackgroundColor: p.surfaceContainerHigh,
          disabledForegroundColor: p.outline,
          elevation: 0,
          textStyle: text(body, 13.5, FontWeight.w600, p.onPrimary),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: p.onSurface,
          side: BorderSide(color: p.outlineVariant),
          textStyle: text(body, 13.5, FontWeight.w600, p.onSurface),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: p.primary,
          textStyle: text(body, 13.5, FontWeight.w600, p.primary),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(foregroundColor: p.onSurfaceVariant),
      ),
      iconTheme: IconThemeData(color: p.onSurfaceVariant),
      listTileTheme: ListTileThemeData(
        iconColor: p.onSurfaceVariant,
        textColor: p.onSurface,
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? p.onPrimary : p.outline,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? p.primary
              : p.surfaceContainerHigh,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? Colors.transparent
              : p.outlineVariant,
        ),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? p.primary : null,
        ),
        checkColor: WidgetStatePropertyAll(p.onPrimary),
        side: BorderSide(color: p.outline, width: 1.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(5)),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? p.primary : p.outline,
        ),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: p.primary,
        inactiveTrackColor: p.surfaceContainerHigh,
        thumbColor: p.primary,
        overlayColor: p.primary.withValues(alpha: 0.14),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: p.primary,
        linearTrackColor: p.surfaceContainerHigh,
        circularTrackColor: Colors.transparent,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF2B384C) : const Color(0xFF1D2939),
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: text(body, 12, FontWeight.w500, Colors.white),
      ),
      dividerTheme: DividerThemeData(color: hairline, thickness: 1, space: 1),
      textTheme: TextTheme(
        displayLarge: text(head, 38, FontWeight.w700, p.onSurface, height: 1.15),
        headlineLarge: text(head, 26, FontWeight.w600, p.onSurface, height: 1.2),
        headlineMedium: text(head, 20, FontWeight.w600, p.onSurface, height: 1.25),
        headlineSmall: text(head, 16, FontWeight.w500, p.onSurface, height: 1.25),
        titleLarge: text(head, 20, FontWeight.w600, p.onSurface, height: 1.25),
        titleMedium: text(body, 15, FontWeight.w600, p.onSurface),
        titleSmall: text(body, 13.5, FontWeight.w600, p.onSurface),
        bodyLarge: text(body, 16, FontWeight.w400, p.onSurface, height: 1.4),
        bodyMedium: text(body, 14, FontWeight.w400, p.onSurface, height: 1.4),
        bodySmall: text(body, 12, FontWeight.w400, p.onSurfaceVariant, height: 1.4),
        labelLarge: text(body, 13, FontWeight.w600, p.onSurface, height: 1.25),
        labelMedium: text(body, 12, FontWeight.w600, p.onSurfaceVariant, height: 1.25),
        labelSmall: text(body, 11, FontWeight.w600, p.onSurfaceVariant, height: 1.25),
      ),
    );
  }
}
