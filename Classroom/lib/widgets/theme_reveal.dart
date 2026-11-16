import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import '../theme/app_colors.dart';
import '../theme/theme_controller.dart';

/// Wraps the whole app and animates theme changes as an expanding circle:
/// the new theme is revealed outward from wherever the user tapped, while a
/// snapshot of the old theme is wiped away around it.
///
/// Use [ThemeReveal.switchTo] instead of calling [ThemeController.setMode]
/// directly when the change is triggered by a tap.
class ThemeReveal extends StatefulWidget {
  final Widget child;

  const ThemeReveal({super.key, required this.child});

  static _ThemeRevealState? _active;

  /// Switches to [mode], revealing the new theme from [origin] (a global
  /// position, typically the centre of the control that was tapped).
  /// Falls back to an instant switch when no host is mounted or the
  /// snapshot cannot be taken.
  static Future<void> switchTo(ThemeMode mode, {Offset? origin}) async {
    final host = _active;
    if (host == null || !host.mounted) {
      await ThemeController().setMode(mode);
      return;
    }
    await host._switchTo(mode, origin);
  }

  /// Flips between light and dark from [origin].
  static Future<void> toggle({Offset? origin}) {
    return switchTo(
      ThemeController().isDark ? ThemeMode.light : ThemeMode.dark,
      origin: origin,
    );
  }

  @override
  State<ThemeReveal> createState() => _ThemeRevealState();
}

class _ThemeRevealState extends State<ThemeReveal>
    with SingleTickerProviderStateMixin {
  final GlobalKey _boundaryKey = GlobalKey();
  late final AnimationController _controller;

  ui.Image? _snapshot;
  Offset _origin = Offset.zero;
  Color _ringColor = Colors.transparent;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 620),
    );
    ThemeReveal._active = this;
  }

  @override
  void dispose() {
    if (ThemeReveal._active == this) ThemeReveal._active = null;
    _controller.dispose();
    _snapshot?.dispose();
    super.dispose();
  }

  Future<void> _switchTo(ThemeMode mode, Offset? origin) async {
    final controller = ThemeController();
    if (_busy) return;

    // Work out whether anything will visibly change. Switching between
    // "system" and an explicit mode that resolves to the same brightness
    // needs no animation.
    final before = controller.effectiveBrightness;
    final after = switch (mode) {
      ThemeMode.light => Brightness.light,
      ThemeMode.dark => Brightness.dark,
      ThemeMode.system =>
        WidgetsBinding.instance.platformDispatcher.platformBrightness,
    };
    if (before == after) {
      await controller.setMode(mode);
      return;
    }

    _busy = true;
    ui.Image? image;
    try {
      final boundary = _boundaryKey.currentContext?.findRenderObject();
      if (boundary is RenderRepaintBoundary) {
        final dpr = MediaQuery.maybeOf(context)?.devicePixelRatio ?? 1.0;
        // Cap the capture resolution: the snapshot is on screen for half a
        // second and is being wiped the whole time.
        image = await boundary.toImage(pixelRatio: math.min(dpr, 2.0));
      }
    } catch (e) {
      debugPrint('[ThemeReveal] Snapshot unavailable, switching instantly: $e');
    }

    if (!mounted) {
      image?.dispose();
      _busy = false;
      await controller.setMode(mode);
      return;
    }

    if (image == null) {
      _busy = false;
      await controller.setMode(mode);
      return;
    }

    final size = MediaQuery.of(context).size;
    HapticFeedback.mediumImpact();
    setState(() {
      _snapshot = image;
      _origin = origin ?? Offset(size.width / 2, size.height / 2);
    });

    // Applies the palette and rebuilds synchronously; persistence continues
    // in the background.
    final saved = controller.setMode(mode);
    _ringColor = AppColors.primary;

    try {
      await _controller.forward(from: 0);
    } finally {
      if (mounted) {
        setState(() => _snapshot = null);
      }
      image.dispose();
      _busy = false;
    }
    await saved;
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = _snapshot;
    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(key: _boundaryKey, child: widget.child),
        if (snapshot != null)
          Positioned.fill(
            // Block input until the wipe finishes so a tap cannot land on a
            // control that is still hidden behind the old snapshot.
            child: AbsorbPointer(
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, _) {
                  return CustomPaint(
                    painter: _RevealPainter(
                      image: snapshot,
                      origin: _origin,
                      progress: Curves.easeInOutCubic
                          .transform(_controller.value),
                      ringColor: _ringColor,
                    ),
                  );
                },
              ),
            ),
          ),
      ],
    );
  }
}

class _RevealPainter extends CustomPainter {
  final ui.Image image;
  final Offset origin;
  final double progress;
  final Color ringColor;

  _RevealPainter({
    required this.image,
    required this.origin,
    required this.progress,
    required this.ringColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Far enough to clear the corner furthest from the origin.
    final maxRadius = [
      origin,
      origin - Offset(size.width, 0),
      origin - Offset(0, size.height),
      origin - Offset(size.width, size.height),
    ].map((o) => o.distance).reduce(math.max);
    final radius = maxRadius * progress;
    final bounds = Offset.zero & size;

    // Old theme everywhere except the growing hole.
    canvas.saveLayer(bounds, Paint());
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      bounds,
      Paint()..filterQuality = FilterQuality.low,
    );
    canvas.drawCircle(origin, radius, Paint()..blendMode = BlendMode.clear);
    canvas.restore();

    // A soft leading edge that fades as the wipe completes.
    final fade = (1.0 - progress).clamp(0.0, 1.0);
    if (radius > 0 && fade > 0) {
      canvas.drawCircle(
        origin,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 10
          ..color = ringColor.withValues(alpha: 0.22 * fade)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
      );
      canvas.drawCircle(
        origin,
        radius,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5
          ..color = ringColor.withValues(alpha: 0.55 * fade),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _RevealPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.image != image ||
        oldDelegate.origin != origin;
  }
}
