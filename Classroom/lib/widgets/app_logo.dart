import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

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
      duration: const Duration(seconds: 4),
    );
    if (widget.animated) {
      _controller.repeat();
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
        return Container(
          width: widget.size,
          height: widget.size,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.size * 0.24),
            color: AppColors.surfaceContainer,
            border: Border.all(
              color: AppColors.primary.withValues(alpha: 0.3),
              width: 1.5,
            ),
            boxShadow: widget.showGlow
                ? [
                    BoxShadow(
                      color: AppColors.primary.withValues(alpha: 0.25),
                      blurRadius: widget.size * 0.4,
                      spreadRadius: widget.size * -0.05,
                    ),
                  ]
                : null,
          ),
          child: CustomPaint(
            painter: _LogoPainter(
              progress: widget.animated ? _controller.value : 0.0,
            ),
          ),
        );
      },
    );
  }
}

class _LogoPainter extends CustomPainter {
  final double progress;

  _LogoPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width * 0.30;

    final linePaint = Paint()
      ..color = AppColors.primary.withValues(alpha: 0.6)
      ..strokeWidth = size.width * 0.04
      ..strokeCap = StrokeCap.round;

    final nodePaint = Paint()
      ..color = AppColors.primary
      ..style = PaintingStyle.fill;

    final corePaint = Paint()
      ..color = AppColors.primary
      ..style = PaintingStyle.fill;

    final innerCorePaint = Paint()
      ..color = AppColors.surfaceContainerLowest
      ..style = PaintingStyle.fill;

    // Draw connecting hub lines & 4 satellite nodes
    const nodeCount = 4;
    final pulseScale = 1.0 + 0.08 * math.sin(progress * 2 * math.pi);
    final nodeRadius = size.width * 0.065;

    for (int i = 0; i < nodeCount; i++) {
      final angle = i * (2 * math.pi / nodeCount) + (math.pi / 4);
      final nx = center.dx + (radius * pulseScale) * math.cos(angle);
      final ny = center.dy + (radius * pulseScale) * math.sin(angle);
      final nodePos = Offset(nx, ny);

      // Branch lines
      canvas.drawLine(center, nodePos, linePaint);

      // Satellite node with outer highlight
      canvas.drawCircle(nodePos, nodeRadius, nodePaint);
      canvas.drawCircle(
        nodePos,
        nodeRadius * 0.45,
        innerCorePaint,
      );
    }

    // Central Core Node
    final coreRadius = size.width * 0.12 * pulseScale;
    canvas.drawCircle(center, coreRadius, corePaint);
    canvas.drawCircle(center, coreRadius * 0.5, innerCorePaint);
  }

  @override
  bool shouldRepaint(covariant _LogoPainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}

