import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_colors.dart';
import '../theme/theme_controller.dart';
import 'theme_reveal.dart';

/// Plays a one-time entrance — fade, rise and settle — when first built.
/// Give list items increasing [index] values to cascade them in.
class Reveal extends StatefulWidget {
  final Widget child;
  final int index;

  /// Delay added per [index] step.
  final Duration stagger;

  /// How far below its resting position the child starts, in pixels.
  final double offset;

  const Reveal({
    super.key,
    required this.child,
    this.index = 0,
    this.stagger = const Duration(milliseconds: 55),
    this.offset = 18,
  });

  @override
  State<Reveal> createState() => _RevealState();
}

class _RevealState extends State<Reveal> with SingleTickerProviderStateMixin {
  static const _travel = Duration(milliseconds: 460);

  late final AnimationController _controller;
  late final Animation<double> _curve;

  @override
  void initState() {
    super.initState();
    // Cap the cascade so the tenth item in a long list is not still waiting
    // half a second after the first one landed.
    final steps = widget.index.clamp(0, 8);
    final delay = widget.stagger * steps;
    final total = delay + _travel;

    _controller = AnimationController(vsync: this, duration: total);
    _curve = CurvedAnimation(
      parent: _controller,
      curve: Interval(
        delay.inMicroseconds / total.inMicroseconds,
        1.0,
        curve: Curves.easeOutCubic,
      ),
    );
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _curve,
      builder: (context, child) {
        final t = _curve.value;
        if (t >= 1.0) return child!;
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, widget.offset * (1 - t)),
            child: child,
          ),
        );
      },
      child: widget.child,
    );
  }
}

/// An integer that counts to its new value instead of snapping.
class AnimatedCount extends StatelessWidget {
  final int value;
  final TextStyle style;
  final String prefix;
  final String suffix;

  const AnimatedCount({
    super.key,
    required this.value,
    required this.style,
    this.prefix = '',
    this.suffix = '',
  });

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: value.toDouble()),
      duration: const Duration(milliseconds: 650),
      curve: Curves.easeOutCubic,
      builder: (context, v, _) {
        return Text(
          '$prefix${v.round()}$suffix',
          style: style,
          maxLines: 1,
        );
      },
    );
  }
}

/// A thin progress bar whose fill eases to its new fraction.
class AnimatedMeter extends StatelessWidget {
  final double fraction;
  final Color color;
  final double height;

  const AnimatedMeter({
    super.key,
    required this.fraction,
    required this.color,
    this.height = 5,
  });

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: fraction.clamp(0.0, 1.0)),
      duration: const Duration(milliseconds: 700),
      curve: Curves.easeOutCubic,
      builder: (context, v, _) {
        return ClipRRect(
          borderRadius: BorderRadius.circular(height / 2),
          child: SizedBox(
            height: height,
            child: Stack(
              children: [
                Positioned.fill(
                  child: ColoredBox(color: AppColors.overlay(0.10)),
                ),
                FractionallySizedBox(
                  widthFactor: v,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(height / 2),
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Shrinks its child slightly while pressed.
class PressScale extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double pressedScale;

  const PressScale({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.pressedScale = 0.95,
  });

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  bool _down = false;

  void _set(bool value) {
    if (_down != value && mounted) setState(() => _down = value);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: widget.onTap == null ? null : (_) => _set(true),
      onTapUp: (_) => _set(false),
      onTapCancel: () => _set(false),
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: AnimatedScale(
        scale: _down ? widget.pressedScale : 1.0,
        duration: const Duration(milliseconds: 110),
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}

/// A square power toggle. Turning it on sends a ring rippling outward and
/// leaves the button lit; turning it off lets the glow fade.
class PowerButton extends StatefulWidget {
  final bool isOn;
  final VoidCallback onTap;
  final double size;
  final double radius;
  final IconData icon;
  final String? semanticLabel;

  const PowerButton({
    super.key,
    required this.isOn,
    required this.onTap,
    this.size = 44,
    this.radius = 13,
    this.icon = Icons.power_settings_new_rounded,
    this.semanticLabel,
  });

  @override
  State<PowerButton> createState() => _PowerButtonState();
}

class _PowerButtonState extends State<PowerButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ripple;

  @override
  void initState() {
    super.initState();
    _ripple = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
    );
  }

  @override
  void didUpdateWidget(covariant PowerButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isOn && !oldWidget.isOn) {
      _ripple.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _ripple.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final on = widget.isOn;
    final size = widget.size;

    return Semantics(
      button: true,
      toggled: on,
      label: widget.semanticLabel,
      child: PressScale(
        pressedScale: 0.9,
        onTap: widget.onTap,
        child: SizedBox(
          width: size,
          height: size,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              // Ripple ring
              AnimatedBuilder(
                animation: _ripple,
                builder: (context, _) {
                  final t = Curves.easeOut.transform(_ripple.value);
                  if (_ripple.value == 0 || _ripple.value == 1) {
                    return const SizedBox.shrink();
                  }
                  return Transform.scale(
                    scale: 1.0 + t * 0.75,
                    child: Container(
                      width: size,
                      height: size,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(widget.radius),
                        border: Border.all(
                          color: AppColors.primary
                              .withValues(alpha: 0.6 * (1 - t)),
                          width: 2,
                        ),
                      ),
                    ),
                  );
                },
              ),
              AnimatedContainer(
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
                width: size,
                height: size,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(widget.radius),
                  color: on ? AppColors.primary : AppColors.surfaceContainerHigh,
                  border: Border.all(
                    color: on ? AppColors.primary : AppColors.overlay(0.08),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.primary
                          .withValues(alpha: on ? 0.38 : 0.0),
                      blurRadius: 14,
                      spreadRadius: -2,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Icon(
                  widget.icon,
                  size: size * 0.5,
                  color: on ? AppColors.onPrimary : AppColors.outline,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// App-bar button that flips between light and dark. The icon morphs between
/// a sun and a crescent moon, and the new theme sweeps out from the button.
class ThemeToggleButton extends StatelessWidget {
  final double size;

  const ThemeToggleButton({super.key, this.size = 38});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ThemeController(),
      builder: (context, _) {
        // Read the palette actually on screen so the icon can never
        // disagree with it.
        final isDark = AppColors.isDark;
        return Tooltip(
          message: isDark ? 'Switch to light mode' : 'Switch to dark mode',
          child: Semantics(
            button: true,
            label: isDark ? 'Switch to light mode' : 'Switch to dark mode',
            child: PressScale(
              pressedScale: 0.88,
              onTap: () {
                HapticFeedback.selectionClick();
                final box = context.findRenderObject() as RenderBox?;
                final origin = box != null && box.hasSize
                    ? box.localToGlobal(box.size.center(Offset.zero))
                    : null;
                ThemeReveal.toggle(origin: origin);
              },
              child: Container(
                width: size,
                height: size,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(size * 0.32),
                  color: AppColors.surfaceContainerHigh,
                  border: Border.all(color: AppColors.overlay(0.08)),
                ),
                child: TweenAnimationBuilder<double>(
                  tween: Tween<double>(end: isDark ? 1.0 : 0.0),
                  duration: const Duration(milliseconds: 520),
                  curve: Curves.easeInOutCubic,
                  builder: (context, t, _) {
                    return CustomPaint(
                      painter: _SunMoonPainter(
                        t: t,
                        color: Color.lerp(
                          AppColors.telemetryAmber,
                          AppColors.primary,
                          t,
                        )!,
                        background: AppColors.surfaceContainerHigh,
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// t = 0 draws a sun (disc + rays); t = 1 draws a crescent moon. In between,
/// the rays retract while a "bite" slides across the disc.
class _SunMoonPainter extends CustomPainter {
  final double t;
  final Color color;
  final Color background;

  _SunMoonPainter({
    required this.t,
    required this.color,
    required this.background,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final unit = size.shortestSide;
    final discRadius = unit * (0.17 + 0.05 * t);

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(-math.pi / 2.2 * t);

    // Rays
    final rayAlpha = (1 - t * 1.6).clamp(0.0, 1.0);
    if (rayAlpha > 0) {
      final rayPaint = Paint()
        ..color = color.withValues(alpha: rayAlpha)
        ..strokeWidth = unit * 0.055
        ..strokeCap = StrokeCap.round;
      final inner = unit * 0.27;
      final outer = unit * (0.27 + 0.08 * (1 - t));
      for (int i = 0; i < 8; i++) {
        final a = i * math.pi / 4;
        final dir = Offset(math.cos(a), math.sin(a));
        canvas.drawLine(dir * inner, dir * outer, rayPaint);
      }
    }

    // Disc with a sliding bite taken out of it.
    final bounds = Rect.fromCircle(center: Offset.zero, radius: unit * 0.5);
    canvas.saveLayer(bounds, Paint());
    canvas.drawCircle(Offset.zero, discRadius, Paint()..color = color);
    final biteOffset = Offset(
      discRadius * (2.2 - 1.75 * t),
      -discRadius * 0.35 * t,
    );
    canvas.drawCircle(
      biteOffset,
      discRadius * 0.92,
      Paint()..blendMode = BlendMode.clear,
    );
    canvas.restore();

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _SunMoonPainter oldDelegate) {
    return oldDelegate.t != t ||
        oldDelegate.color != color ||
        oldDelegate.background != background;
  }
}

/// Slow, drifting colour fields for hero areas (splash, sign-in, the
/// dashboard header). Purely decorative; sits behind content.
class AmbientBackground extends StatefulWidget {
  /// 0–1 multiplier on the colour strength.
  final double intensity;
  final BorderRadius borderRadius;

  const AmbientBackground({
    super.key,
    this.intensity = 1.0,
    this.borderRadius = BorderRadius.zero,
  });

  @override
  State<AmbientBackground> createState() => _AmbientBackgroundState();
}

class _AmbientBackgroundState extends State<AmbientBackground>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 22),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: ClipRRect(
        borderRadius: widget.borderRadius,
        child: RepaintBoundary(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              return CustomPaint(
                size: Size.infinite,
                painter: _AmbientPainter(
                  phase: _controller.value * 2 * math.pi,
                  intensity: widget.intensity,
                  a: AppColors.primary,
                  b: AppColors.secondary,
                  c: AppColors.onlineMint,
                  dark: AppColors.isDark,
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _AmbientPainter extends CustomPainter {
  final double phase;
  final double intensity;
  final Color a;
  final Color b;
  final Color c;
  final bool dark;

  _AmbientPainter({
    required this.phase,
    required this.intensity,
    required this.a,
    required this.b,
    required this.c,
    required this.dark,
  });

  void _blob(Canvas canvas, Size size, Offset centre, double radius, Color color) {
    final rect = Rect.fromCircle(center: centre, radius: radius);
    canvas.drawCircle(
      centre,
      radius,
      Paint()
        ..shader = RadialGradient(
          colors: [color, color.withValues(alpha: 0)],
        ).createShader(rect),
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final reach = math.max(w, h);
    final strength = (dark ? 0.22 : 0.16) * intensity;

    _blob(
      canvas,
      size,
      Offset(w * (0.18 + 0.10 * math.sin(phase)), h * (0.20 + 0.08 * math.cos(phase))),
      reach * 0.62,
      a.withValues(alpha: strength),
    );
    _blob(
      canvas,
      size,
      Offset(w * (0.88 + 0.08 * math.cos(phase * 1.0 + 1.3)), h * (0.42 + 0.12 * math.sin(phase + 0.7))),
      reach * 0.58,
      b.withValues(alpha: strength),
    );
    _blob(
      canvas,
      size,
      Offset(w * (0.40 + 0.14 * math.sin(phase + 2.4)), h * (0.95 + 0.06 * math.cos(phase + 2.0))),
      reach * 0.50,
      c.withValues(alpha: strength * 0.7),
    );
  }

  @override
  bool shouldRepaint(covariant _AmbientPainter oldDelegate) {
    return oldDelegate.phase != phase ||
        oldDelegate.dark != dark ||
        oldDelegate.intensity != intensity;
  }
}

/// An [IndexedStack] that keeps every tab alive but cross-fades and lifts
/// the newly selected one into place.
class FadeIndexedStack extends StatefulWidget {
  final int index;
  final List<Widget> children;

  const FadeIndexedStack({
    super.key,
    required this.index,
    required this.children,
  });

  @override
  State<FadeIndexedStack> createState() => _FadeIndexedStackState();
}

class _FadeIndexedStackState extends State<FadeIndexedStack>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  int _direction = 1;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
      value: 1.0,
    );
  }

  @override
  void didUpdateWidget(covariant FadeIndexedStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) {
      _direction = widget.index > oldWidget.index ? 1 : -1;
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = Curves.easeOutCubic.transform(_controller.value);
        if (t >= 1.0) return child!;
        return Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(_direction * 22.0 * (1 - t), 0),
            child: child,
          ),
        );
      },
      child: IndexedStack(index: widget.index, children: widget.children),
    );
  }
}
