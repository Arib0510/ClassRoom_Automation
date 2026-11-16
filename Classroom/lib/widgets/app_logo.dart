import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

/// The ClassPulse mark: a hub with four satellite nodes on a gradient tile.
/// When [animated], the nodes breathe outward and a pulse travels along each
/// spoke from the hub — the "pulse" in the name.
class ClassPulseLogo extends StatefulWidget {
  final double size;
  final bool animated;
  final bool showGlow;

  const ClassPulseLogo({
    super.key,
    this.size = 48.0,
    this.animated = true,
    this.showGlow = true,
  });

  @override
  State<ClassPulseLogo> createState() => _ClassPulseLogoState();
}

class _ClassPulseLogoState extends State<ClassPulseLogo>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3200),
    );
    if (widget.animated) {
      _controller.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant ClassPulseLogo oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animated && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.animated && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.28),
        gradient: LinearGradient(
          colors: [
            BrandColors.logoStart,
            BrandColors.logoEnd,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: widget.showGlow
            ? [
                BoxShadow(
                  color: BrandColors.logoEnd.withValues(
                    alpha: AppColors.isDark ? 0.35 : 0.28,
                  ),
                  blurRadius: size * 0.42,
                  spreadRadius: size * -0.08,
                  offset: Offset(0, size * 0.12),
                ),
              ]
            : null,
      ),
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return CustomPaint(
            painter: _LogoPainter(
              progress: widget.animated ? _controller.value : 0.0,
              animated: widget.animated,
            ),
          );
        },
      ),
    );
  }
}

/// Brand colours for the logo tile. These stay the same in both themes so
/// the mark is always recognisable.
class BrandColors {
  BrandColors._();

  static const Color logoStart = Color(0xFF2F5BDB);
  static const Color logoEnd = Color(0xFF16B8D9);
}

class _LogoPainter extends CustomPainter {
  final double progress;
  final bool animated;

  _LogoPainter({required this.progress, required this.animated});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final breathe =
        animated ? 1.0 + 0.05 * math.sin(progress * 2 * math.pi) : 1.0;
    final radius = size.width * 0.27 * breathe;
    final nodeRadius = size.width * 0.068;

    final linePaint = Paint()
      ..color = AppColors.overlay(0.55)
      ..strokeWidth = size.width * 0.045
      ..strokeCap = StrokeCap.round;
    final nodePaint = Paint()..color = Colors.white;

    const nodeCount = 4;
    for (int i = 0; i < nodeCount; i++) {
      final angle = i * (2 * math.pi / nodeCount) + (math.pi / 4);
      final dir = Offset(math.cos(angle), math.sin(angle));
      final nodePos = center + dir * radius;

      canvas.drawLine(center, nodePos, linePaint);
      canvas.drawCircle(nodePos, nodeRadius, nodePaint);

      if (animated) {
        // A pulse leaving the hub, staggered per spoke.
        final t = (progress * 2 + i / nodeCount) % 1.0;
        canvas.drawCircle(
          center + dir * (radius * t),
          size.width * 0.032,
          Paint()
            ..color = Colors.white
                .withValues(alpha: math.sin(t * math.pi).clamp(0.0, 1.0)),
        );
      }
    }

    // Hub with a hollow centre.
    final coreRadius = size.width * 0.115;
    canvas.drawCircle(center, coreRadius, nodePaint);
    canvas.drawCircle(
      center,
      coreRadius * 0.46,
      Paint()..color = BrandColors.logoStart,
    );
  }

  @override
  bool shouldRepaint(covariant _LogoPainter oldDelegate) {
    return oldDelegate.progress != progress ||
        oldDelegate.animated != animated;
  }
}
