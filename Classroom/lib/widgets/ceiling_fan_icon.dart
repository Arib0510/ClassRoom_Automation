import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

class CeilingFanIcon extends StatelessWidget {
  final double size;
  final Color color;
  final double angle; // in radians

  const CeilingFanIcon({
    super.key,
    this.size = 24.0,
    this.color = AppColors.primary,
    this.angle = 0.0,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _CeilingFanPainter(
          color: color,
          angle: angle,
        ),
      ),
    );
  }
}

class _CeilingFanPainter extends CustomPainter {
  final Color color;
  final double angle;

  _CeilingFanPainter({
    required this.color,
    required this.angle,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(angle);

    final bladePaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    final hubPaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    final centerCapPaint = Paint()
      ..color = AppColors.surfaceContainerLowest
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;

    // Draw 3 aerodynamic ceiling fan blades at 0, 120, and 240 degrees
    for (int i = 0; i < 3; i++) {
      canvas.save();
      canvas.rotate(i * 2 * math.pi / 3);

      final path = Path();
      final bladeStart = radius * 0.28;
      final bladeEnd = radius * 0.95;
      final bladeHalfWidthNear = radius * 0.09;
      final bladeHalfWidthFar = radius * 0.17;

      // Aerodynamic paddle blade shape
      path.moveTo(bladeHalfWidthNear, -bladeStart);
      path.lineTo(bladeHalfWidthFar, -bladeEnd * 0.85);
      path.quadraticBezierTo(
        0,
        -bladeEnd,
        -bladeHalfWidthFar,
        -bladeEnd * 0.85,
      );
      path.lineTo(-bladeHalfWidthNear, -bladeStart);
      path.close();

      canvas.drawPath(path, bladePaint);
      canvas.restore();
    }

    // Central Motor Hub Housing
    canvas.drawCircle(Offset.zero, radius * 0.32, hubPaint);
    // Rotor cap center rivet
    canvas.drawCircle(Offset.zero, radius * 0.14, centerCapPaint);

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _CeilingFanPainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.angle != angle;
  }
}
