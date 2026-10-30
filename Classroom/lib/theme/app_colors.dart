import 'package:flutter/material.dart';

class AppColors {
  // Foundational Canvas
  static const Color surfaceContainerLowest = Color(0xFF0A0E1A); // Deep Void Navy
  static const Color surfaceDim = Color(0xFF0F131F);
  static const Color surface = Color(0xFF0F131F);
  static const Color surfaceContainerLow = Color(0xFF171B28);
  static const Color surfaceContainer = Color(0xFF1B1F2C);
  static const Color surfaceContainerHigh = Color(0xFF262A37);
  static const Color surfaceContainerHighest = Color(0xFF313442);
  static const Color surfaceBright = Color(0xFF353946);

  // Hyper Cybernetic Primaries
  static const Color primary = Color(0xFF00E5FF); // Hyper Cyan
  static const Color primaryContainer = Color(0xFF00E5FF);
  static const Color primaryLight = Color(0xFFC3F5FF);
  static const Color onPrimary = Color(0xFF00363D);
  static const Color onPrimaryFixed = Color(0xFF001F24);
  static const Color primaryFixedDim = Color(0xFF00DAF3);

  // Electric Secondary (Network & Accents)
  static const Color secondary = Color(0xFF3D7BFF); // Electric Azure
  static const Color secondaryContainer = Color(0xFF045CE0);
  static const Color secondaryLight = Color(0xFFB2C5FF);
  static const Color onSecondary = Color(0xFF002B73);

  // Tertiary
  static const Color tertiary = Color(0xFF102A54); // Midnight Indigo
  static const Color tertiaryContainer = Color(0xFFBCD0FF);
  static const Color onTertiary = Color(0xFF17305A);

  // Surface Text & Variants
  static const Color onSurface = Color(0xFFDFE2F3);
  static const Color onSurfaceVariant = Color(0xFFBAC9CC);
  static const Color outline = Color(0xFF849396);
  static const Color outlineVariant = Color(0xFF3B494C);

  // Telemetry & States
  static const Color onlineMint = Color(0xFF00F5A0);
  static const Color telemetryAmber = Color(0xFFFFB300);
  static const Color criticalRed = Color(0xFFFF3366);
  static const Color error = Color(0xFFFF3366);
  static const Color errorContainer = Color(0xFF93000A);
  static const Color onError = Color(0xFF690005);

  // Gradients & Glows
  static const LinearGradient primaryGradient = LinearGradient(
    colors: [Color(0xFF045CE0), Color(0xFF00E5FF)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient glassGradient = LinearGradient(
    colors: [
      Color(0x331B2A4A),
      Color(0x1F0F1B30),
    ],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static BoxShadow cyanGlow({double radius = 24.0, double spread = -4.0, double opacity = 0.28}) {
    return BoxShadow(
      color: primary.withValues(alpha: opacity),
      blurRadius: radius,
      spreadRadius: spread,
    );
  }

  static BoxShadow blueGlow({double radius = 24.0, double spread = -4.0, double opacity = 0.25}) {
    return BoxShadow(
      color: secondary.withValues(alpha: opacity),
      blurRadius: radius,
      spreadRadius: spread,
    );
  }
}

