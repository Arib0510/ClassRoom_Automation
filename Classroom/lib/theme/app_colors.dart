import 'package:flutter/material.dart';

/// One complete set of colour roles. The app ships two: [AppPalette.dark]
/// and [AppPalette.light]. Widgets never reference a palette directly — they
/// read the active one through [AppColors].
class AppPalette {
  final Brightness brightness;

  // Surfaces, from the page background up to the most raised layer.
  final Color surfaceContainerLowest;
  final Color surfaceDim;
  final Color surface;
  final Color surfaceContainerLow;
  final Color surfaceContainer;
  final Color surfaceContainerHigh;
  final Color surfaceContainerHighest;
  final Color surfaceBright;

  /// Background for dialogs, bottom sheets and menus.
  final Color sheet;

  // Brand / primary.
  final Color primary;
  final Color primaryContainer;
  final Color primaryLight;
  final Color onPrimary;
  final Color onPrimaryFixed;
  final Color primaryFixedDim;

  // Secondary.
  final Color secondary;
  final Color secondaryContainer;
  final Color secondaryLight;
  final Color onSecondary;

  // Tertiary.
  final Color tertiary;
  final Color tertiaryContainer;
  final Color onTertiary;

  // Text and lines.
  final Color onSurface;
  final Color onSurfaceVariant;
  final Color outline;
  final Color outlineVariant;

  // Status.
  final Color onlineMint;
  final Color telemetryAmber;
  final Color criticalRed;
  final Color errorContainer;
  final Color onError;

  /// Text/icon colour on top of a solid status colour (amber, red, mint).
  final Color onAccent;

  /// Base colour for hairlines and faint fills; see [AppColors.overlay].
  final Color overlayBase;
  final double overlayScale;

  /// Base colour for drop shadows; see [AppColors.shadow].
  final Color shadowBase;
  final double shadowScale;

  // Room category accents.
  final Color roomLab;
  final Color roomSeminar;
  final Color roomLecture;
  final Color roomAuditorium;

  const AppPalette({
    required this.brightness,
    required this.surfaceContainerLowest,
    required this.surfaceDim,
    required this.surface,
    required this.surfaceContainerLow,
    required this.surfaceContainer,
    required this.surfaceContainerHigh,
    required this.surfaceContainerHighest,
    required this.surfaceBright,
    required this.sheet,
    required this.primary,
    required this.primaryContainer,
    required this.primaryLight,
    required this.onPrimary,
    required this.onPrimaryFixed,
    required this.primaryFixedDim,
    required this.secondary,
    required this.secondaryContainer,
    required this.secondaryLight,
    required this.onSecondary,
    required this.tertiary,
    required this.tertiaryContainer,
    required this.onTertiary,
    required this.onSurface,
    required this.onSurfaceVariant,
    required this.outline,
    required this.outlineVariant,
    required this.onlineMint,
    required this.telemetryAmber,
    required this.criticalRed,
    required this.errorContainer,
    required this.onError,
    required this.onAccent,
    required this.overlayBase,
    required this.overlayScale,
    required this.shadowBase,
    required this.shadowScale,
    required this.roomLab,
    required this.roomSeminar,
    required this.roomLecture,
    required this.roomAuditorium,
  });

  /// Midnight — deep ink surfaces with a calm sky-cyan accent.
  static const AppPalette dark = AppPalette(
    brightness: Brightness.dark,
    surfaceContainerLowest: Color(0xFF0B0F17),
    surfaceDim: Color(0xFF0E131C),
    surface: Color(0xFF0F141D),
    surfaceContainerLow: Color(0xFF131A25),
    surfaceContainer: Color(0xFF172030),
    surfaceContainerHigh: Color(0xFF1E2838),
    surfaceContainerHighest: Color(0xFF283447),
    surfaceBright: Color(0xFF33415A),
    sheet: Color(0xFF161E2B),
    primary: Color(0xFF3DD6F5),
    primaryContainer: Color(0xFF3DD6F5),
    primaryLight: Color(0xFFB8F0FB),
    onPrimary: Color(0xFF00222B),
    onPrimaryFixed: Color(0xFF00222B),
    primaryFixedDim: Color(0xFF22B8D6),
    secondary: Color(0xFF7C96FF),
    secondaryContainer: Color(0xFF3457D5),
    secondaryLight: Color(0xFFB9C7FF),
    onSecondary: Color(0xFF0A1A4D),
    tertiary: Color(0xFF15294D),
    tertiaryContainer: Color(0xFFBCD0FF),
    onTertiary: Color(0xFF17305A),
    onSurface: Color(0xFFE8ECF3),
    onSurfaceVariant: Color(0xFFB6C0CF),
    outline: Color(0xFF8793A6),
    outlineVariant: Color(0xFF3A4658),
    onlineMint: Color(0xFF3DDC97),
    telemetryAmber: Color(0xFFFFC145),
    criticalRed: Color(0xFFFF6B81),
    errorContainer: Color(0xFF5C1524),
    onError: Color(0xFF2B0710),
    onAccent: Color(0xFF10141C),
    overlayBase: Color(0xFFFFFFFF),
    overlayScale: 1.0,
    shadowBase: Color(0xFF000000),
    shadowScale: 1.0,
    roomLab: Color(0xFF3DD6F5),
    roomSeminar: Color(0xFFFFC145),
    roomLecture: Color(0xFF3DDC97),
    roomAuditorium: Color(0xFFB98CFF),
  );

  /// Daylight — cool paper surfaces with a deep teal accent. Every text and
  /// status colour here clears 4.5:1 against the white card surface.
  static const AppPalette light = AppPalette(
    brightness: Brightness.light,
    surfaceContainerLowest: Color(0xFFF2F5F9),
    surfaceDim: Color(0xFFE9EDF3),
    surface: Color(0xFFF7F9FC),
    surfaceContainerLow: Color(0xFFFFFFFF),
    surfaceContainer: Color(0xFFFFFFFF),
    surfaceContainerHigh: Color(0xFFE9EEF4),
    surfaceContainerHighest: Color(0xFFDCE3EC),
    surfaceBright: Color(0xFFCBD4E0),
    sheet: Color(0xFFFFFFFF),
    primary: Color(0xFF0B7189),
    primaryContainer: Color(0xFF0B7189),
    primaryLight: Color(0xFF155E75),
    onPrimary: Color(0xFFFFFFFF),
    onPrimaryFixed: Color(0xFFFFFFFF),
    primaryFixedDim: Color(0xFF0E8CA8),
    secondary: Color(0xFF3B5BDB),
    secondaryContainer: Color(0xFF2F4AC0),
    secondaryLight: Color(0xFF2F4AC0),
    onSecondary: Color(0xFFFFFFFF),
    tertiary: Color(0xFFDCE6FF),
    tertiaryContainer: Color(0xFF2F4AC0),
    onTertiary: Color(0xFF17305A),
    onSurface: Color(0xFF111827),
    onSurfaceVariant: Color(0xFF465467),
    outline: Color(0xFF66738A),
    outlineVariant: Color(0xFFC9D1DC),
    onlineMint: Color(0xFF047857),
    telemetryAmber: Color(0xFFB45309),
    criticalRed: Color(0xFFD92D20),
    errorContainer: Color(0xFFFEE4E2),
    onError: Color(0xFFFFFFFF),
    onAccent: Color(0xFFFFFFFF),
    overlayBase: Color(0xFF101828),
    overlayScale: 1.25,
    shadowBase: Color(0xFF1D2939),
    shadowScale: 0.22,
    roomLab: Color(0xFF0B7189),
    roomSeminar: Color(0xFFB45309),
    roomLecture: Color(0xFF047857),
    roomAuditorium: Color(0xFF7E3AF2),
  );
}

/// Theme-aware colour roles. These are getters, not constants: they resolve
/// against whichever palette is active, so the same widget code renders in
/// both light and dark mode. `ThemeController` switches the palette.
class AppColors {
  AppColors._();

  static AppPalette _p = AppPalette.dark;

  static AppPalette get palette => _p;
  static bool get isDark => _p.brightness == Brightness.dark;
  static Brightness get brightness => _p.brightness;

  /// Activates the palette for [brightness]. Called by `ThemeController`.
  static void apply(Brightness brightness) {
    _p = brightness == Brightness.dark ? AppPalette.dark : AppPalette.light;
  }

  // Surfaces
  static Color get surfaceContainerLowest => _p.surfaceContainerLowest;
  static Color get surfaceDim => _p.surfaceDim;
  static Color get surface => _p.surface;
  static Color get surfaceContainerLow => _p.surfaceContainerLow;
  static Color get surfaceContainer => _p.surfaceContainer;
  static Color get surfaceContainerHigh => _p.surfaceContainerHigh;
  static Color get surfaceContainerHighest => _p.surfaceContainerHighest;
  static Color get surfaceBright => _p.surfaceBright;
  static Color get sheet => _p.sheet;

  // Primary
  static Color get primary => _p.primary;
  static Color get primaryContainer => _p.primaryContainer;
  static Color get primaryLight => _p.primaryLight;
  static Color get onPrimary => _p.onPrimary;
  static Color get onPrimaryFixed => _p.onPrimaryFixed;
  static Color get primaryFixedDim => _p.primaryFixedDim;

  // Secondary
  static Color get secondary => _p.secondary;
  static Color get secondaryContainer => _p.secondaryContainer;
  static Color get secondaryLight => _p.secondaryLight;
  static Color get onSecondary => _p.onSecondary;

  // Tertiary
  static Color get tertiary => _p.tertiary;
  static Color get tertiaryContainer => _p.tertiaryContainer;
  static Color get onTertiary => _p.onTertiary;

  // Text and lines
  static Color get onSurface => _p.onSurface;
  static Color get onSurfaceVariant => _p.onSurfaceVariant;
  static Color get outline => _p.outline;
  static Color get outlineVariant => _p.outlineVariant;

  // Status
  static Color get onlineMint => _p.onlineMint;
  static Color get telemetryAmber => _p.telemetryAmber;
  static Color get criticalRed => _p.criticalRed;
  static Color get error => _p.criticalRed;
  static Color get errorContainer => _p.errorContainer;
  static Color get onError => _p.onError;
  static Color get onAccent => _p.onAccent;

  /// A hairline / faint-fill colour: white-on-dark or ink-on-light at the
  /// given strength. Use for borders, dividers, drag handles and inert fills.
  static Color overlay(double alpha) => _p.overlayBase
      .withValues(alpha: (alpha * _p.overlayScale).clamp(0.0, 1.0));

  /// A drop-shadow colour. Shadows that read well on a dark page are far too
  /// heavy on a light one, so the light palette scales them down.
  static Color shadow(double alpha) => _p.shadowBase
      .withValues(alpha: (alpha * _p.shadowScale).clamp(0.0, 1.0));

  /// Dimmed backdrop behind dialogs and sheets.
  static Color get scrim =>
      isDark ? const Color(0xB8000000) : const Color(0x7A101828);

  /// Accent colour for a classroom category ("Laboratory", "Seminar Room"…).
  static Color roomType(String roomType) {
    final lower = roomType.toLowerCase();
    if (lower.contains('lab')) return _p.roomLab;
    if (lower.contains('seminar')) return _p.roomSeminar;
    if (lower.contains('lecture')) return _p.roomLecture;
    if (lower.contains('auditorium')) return _p.roomAuditorium;
    return _p.primary;
  }

  // Gradients
  static LinearGradient get primaryGradient => LinearGradient(
        colors: [_p.secondaryContainer, _p.primary],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      );

  static LinearGradient get glassGradient => LinearGradient(
        colors: isDark
            ? const [Color(0x331B2A4A), Color(0x1F0F1B30)]
            : const [Color(0xF2FFFFFF), Color(0xD9F2F5F9)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      );

  /// Soft elevation for cards: a real shadow in light mode, a faint one in
  /// dark mode where surface tone carries most of the depth.
  static List<BoxShadow> cardShadow({double strength = 1.0}) => [
        BoxShadow(
          color: shadow(0.32 * strength),
          blurRadius: 18,
          spreadRadius: -6,
          offset: const Offset(0, 8),
        ),
      ];

  static BoxShadow cyanGlow({
    double radius = 24.0,
    double spread = -4.0,
    double opacity = 0.28,
  }) {
    return BoxShadow(
      color: primary.withValues(alpha: isDark ? opacity : opacity * 0.6),
      blurRadius: radius,
      spreadRadius: spread,
    );
  }

  static BoxShadow blueGlow({
    double radius = 24.0,
    double spread = -4.0,
    double opacity = 0.25,
  }) {
    return BoxShadow(
      color: secondary.withValues(alpha: isDark ? opacity : opacity * 0.6),
      blurRadius: radius,
      spreadRadius: spread,
    );
  }
}
