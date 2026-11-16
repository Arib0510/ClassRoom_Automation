import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_colors.dart';
import 'app_theme.dart';

/// Owns the user's appearance preference (system / light / dark), persists
/// it, and keeps [AppColors] pointed at the matching palette.
class ThemeController extends ChangeNotifier with WidgetsBindingObserver {
  static final ThemeController _instance = ThemeController._internal();
  factory ThemeController() => _instance;
  ThemeController._internal();

  static const String _prefsKey = 'classpulse_theme_mode';

  ThemeMode _mode = ThemeMode.system;
  bool _observing = false;

  ThemeMode get mode => _mode;

  /// The brightness actually on screen once "system" is resolved.
  Brightness get effectiveBrightness {
    switch (_mode) {
      case ThemeMode.light:
        return Brightness.light;
      case ThemeMode.dark:
        return Brightness.dark;
      case ThemeMode.system:
        return WidgetsBinding
            .instance.platformDispatcher.platformBrightness;
    }
  }

  bool get isDark => effectiveBrightness == Brightness.dark;

  /// Reads the saved preference and activates its palette. Call once before
  /// `runApp` so the first frame is already in the right theme.
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _mode = _decode(prefs.getString(_prefsKey));
    } catch (e) {
      debugPrint('[ThemeController] Could not read saved theme: $e');
    }
    if (!_observing) {
      WidgetsBinding.instance.addObserver(this);
      _observing = true;
    }
    _applyPalette();
  }

  /// Changes the preference. Does nothing visible if the resolved brightness
  /// is unchanged (e.g. switching System → Dark while the phone is dark).
  Future<void> setMode(ThemeMode mode) async {
    if (mode == _mode) return;
    final before = effectiveBrightness;
    _mode = mode;
    if (effectiveBrightness != before) {
      _applyPalette();
      _rebuildEverything();
    }
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_prefsKey, _encode(mode));
    } catch (e) {
      debugPrint('[ThemeController] Could not save theme: $e');
    }
  }

  /// Flips between light and dark, leaving "system" behind.
  Future<void> toggle() =>
      setMode(isDark ? ThemeMode.light : ThemeMode.dark);

  @override
  void didChangePlatformBrightness() {
    if (_mode != ThemeMode.system) return;
    if (AppColors.brightness == effectiveBrightness) return;
    _applyPalette();
    _rebuildEverything();
    notifyListeners();
  }

  void _applyPalette() {
    AppColors.apply(effectiveBrightness);
    SystemChrome.setSystemUIOverlayStyle(
      AppTheme.overlayStyle(AppColors.palette),
    );
  }

  /// [AppColors] roles are plain getters rather than inherited-widget
  /// lookups, so nothing depends on them and nothing would rebuild by itself
  /// when the palette flips. Mark the whole tree dirty instead — a theme
  /// switch is rare, and a single full rebuild is cheap.
  void _rebuildEverything() {
    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return;

    void visit(Element element) {
      element.markNeedsBuild();
      // Custom painters whose inputs did not change would otherwise skip
      // repainting and keep the old palette's colours.
      final renderObject = element is RenderObjectElement
          ? element.renderObject
          : null;
      if (renderObject is RenderBox && renderObject.attached) {
        renderObject.markNeedsPaint();
      }
      element.visitChildren(visit);
    }

    root.visitChildren(visit);
  }

  static ThemeMode _decode(String? value) {
    switch (value) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  static String _encode(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return 'light';
      case ThemeMode.dark:
        return 'dark';
      case ThemeMode.system:
        return 'system';
    }
  }
}
