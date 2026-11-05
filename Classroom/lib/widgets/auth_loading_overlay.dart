import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_typography.dart';
import 'app_logo.dart';

class AuthLoadingOverlay extends StatefulWidget {
  final bool isLogin;
  final String title;

  const AuthLoadingOverlay({
    super.key,
    required this.isLogin,
    this.title = '',
  });

  @override
  State<AuthLoadingOverlay> createState() => _AuthLoadingOverlayState();
}

class _AuthLoadingOverlayState extends State<AuthLoadingOverlay>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  int _statusIndex = 0;

  late final List<String> _loginStages = [
    'CONNECTING TO SECURE FIREBASE MESH...',
    'VERIFYING CRYPTOGRAPHIC OPERATOR TOKEN...',
    'SYNCHRONIZING ESP32 HARDWARE REGISTERS...',
    'ACCESS AUTHORIZED // INITIALIZING CONSOLE...',
  ];

  late final List<String> _registerStages = [
    'PROVISIONING OPERATOR IDENTITY ON FIREBASE...',
    'ENCRYPTING LOCAL MESH CREDENTIALS...',
    'CONFIGURING CAMPUS ZONE PERMISSIONS...',
    'IDENTITY CONFIRMED // PROVISION COMPLETE...',
  ];

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat();

    _cycleStatusStages();
  }

  void _cycleStatusStages() async {
    for (int i = 0; i < 4; i++) {
      if (!mounted) return;
      await Future.delayed(const Duration(milliseconds: 450));
      if (mounted) {
        setState(() {
          _statusIndex = (i + 1) % 4;
        });
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final stages = widget.isLogin ? _loginStages : _registerStages;
    final currentStatus = stages[_statusIndex];

    return Material(
      color: Colors.transparent,
      child: Stack(
        children: [
          // Blur backdrop
          Positioned.fill(
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
              child: Container(
                color: Colors.black.withValues(alpha: 0.75),
              ),
            ),
          ),

          // Centered Cyber Auth Card
          Center(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 28),
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(20),
                color: const Color(0xE60A101D),
                border: Border.all(
                  color: AppColors.primary.withValues(alpha: 0.6),
                  width: 1.5,
                ),
                boxShadow: [
                  AppColors.cyanGlow(radius: 36, opacity: 0.35),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Rotating Holographic Radar Rings with Logo Center
                  SizedBox(
                    width: 110,
                    height: 110,
                    child: AnimatedBuilder(
                      animation: _controller,
                      builder: (context, child) {
                        return CustomPaint(
                          painter: _CyberRadarPainter(progress: _controller.value),
                          child: const Center(
                            child: ClassPulseLogo(size: 40, animated: true),
                          ),
                        );
                      },
                    ),
                  ),

                  const SizedBox(height: 22),

                  // Main Title
                  Text(
                    widget.title.isNotEmpty
                        ? widget.title
                        : (widget.isLogin ? 'AUTHENTICATING OPERATOR' : 'PROVISIONING IDENTITY'),
                    style: AppTypography.headlineSm(color: AppColors.onSurface).copyWith(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1.2,
                    ),
                    textAlign: TextAlign.center,
                  ),

                  const SizedBox(height: 10),

                  // Animated Status Terminal Message
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      color: AppColors.surfaceContainerLowest,
                      border: Border.all(color: AppColors.primary.withValues(alpha: 0.2)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 6,
                          height: 6,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppColors.primary,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Flexible(
                          child: AnimatedSwitcher(
                            duration: const Duration(milliseconds: 250),
                            child: Text(
                              currentStatus,
                              key: ValueKey(currentStatus),
                              style: AppTypography.labelSm(color: AppColors.primary).copyWith(
                                fontSize: 10,
                                letterSpacing: 0.5,
                              ),
                              textAlign: TextAlign.center,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 20),

                  // Neon Beam Scanning Progress Bar
                  AnimatedBuilder(
                    animation: _controller,
                    builder: (context, child) {
                      return ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: Container(
                          height: 4,
                          width: double.infinity,
                          color: AppColors.surfaceContainerHigh,
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              final beamWidth = constraints.maxWidth * 0.45;
                              final offset = (constraints.maxWidth + beamWidth) * _controller.value - beamWidth;
                              return Stack(
                                children: [
                                  Positioned(
                                    left: offset,
                                    width: beamWidth,
                                    height: 4,
                                    child: Container(
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(
                                          colors: [
                                            AppColors.primary.withValues(alpha: 0.0),
                                            AppColors.primary,
                                            AppColors.primaryLight,
                                            AppColors.primary.withValues(alpha: 0.0),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CyberRadarPainter extends CustomPainter {
  final double progress;

  _CyberRadarPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final outerRadius = size.width / 2;
    final innerRadius = outerRadius * 0.72;

    // Outer rotating segmented ring (clockwise)
    final outerPaint = Paint()
      ..color = AppColors.primary.withValues(alpha: 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8;

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(progress * 2 * math.pi);

    for (int i = 0; i < 4; i++) {
      final startAngle = i * (math.pi / 2) + 0.15;
      canvas.drawArc(
        Rect.fromCircle(center: Offset.zero, radius: outerRadius),
        startAngle,
        math.pi / 2 - 0.3,
        false,
        outerPaint,
      );
    }

    // Tick marks on outer ring
    final tickPaint = Paint()
      ..color = AppColors.primaryLight
      ..strokeWidth = 2.0;

    for (int i = 0; i < 8; i++) {
      final angle = i * (math.pi / 4);
      final p1 = Offset(math.cos(angle) * (outerRadius - 4), math.sin(angle) * (outerRadius - 4));
      final p2 = Offset(math.cos(angle) * (outerRadius + 2), math.sin(angle) * (outerRadius + 2));
      canvas.drawLine(p1, p2, tickPaint);
    }

    canvas.restore();

    // Inner counter-clockwise rotating ring
    final innerPaint = Paint()
      ..color = AppColors.secondary.withValues(alpha: 0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(-progress * 2 * math.pi * 1.5);

    for (int i = 0; i < 3; i++) {
      final startAngle = i * (2 * math.pi / 3) + 0.2;
      canvas.drawArc(
        Rect.fromCircle(center: Offset.zero, radius: innerRadius),
        startAngle,
        (2 * math.pi / 3) - 0.4,
        false,
        innerPaint,
      );
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _CyberRadarPainter oldDelegate) {
    return oldDelegate.progress != progress;
  }
}
