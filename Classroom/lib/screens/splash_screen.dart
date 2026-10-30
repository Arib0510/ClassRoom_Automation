import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:permission_handler/permission_handler.dart';
import '../state/auth_state.dart';
import '../theme/app_colors.dart';
import '../theme/app_typography.dart';
import '../widgets/app_logo.dart';
import '../widgets/pulsing_beacon.dart';
import '../widgets/route_transitions.dart';
import 'auth_screen.dart';
import 'dashboard_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  late AnimationController _pulseController;
  late AnimationController _radarController;
  late AnimationController _fadeController;

  final List<String> _telemetryStages = [
    'Initializing classroom nodes...',
    'Resolving BACnet IP controllers...',
    'Syncing Lutron lighting arrays...',
    'Acoustic beamforming calibrated...',
    'Ready • Handshake complete',
  ];

  int _currentStage = 0;
  Timer? _telemetryTimer;
  Timer? _autoNavTimer;

  Future<void> _startAppFlow() async {
    // 1. Request necessary storage and hardware permissions on startup
    try {
      await [
        Permission.photos,
        Permission.storage,
        Permission.locationWhenInUse,
      ].request();
    } catch (e) {
      debugPrint('Startup permissions request error: $e');
    }

    // 2. Allow telemetry animation at least 2.5 seconds total before proceeding
    await Future.delayed(const Duration(milliseconds: 2500));
    if (mounted) {
      _navigateToNext();
    }
  }

  @override
  void initState() {
    super.initState();

    // Restore any active persistent session from disk immediately
    AuthState().loadPersistedSession();
    _startAppFlow();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();

    _radarController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    )..repeat();

    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..forward();

    _telemetryTimer = Timer.periodic(const Duration(milliseconds: 1400), (t) {
      if (!mounted) return;
      setState(() {
        _currentStage = (_currentStage + 1) % _telemetryStages.length;
      });
    });
  }

  void _navigateToNext() {
    if (!mounted) return;
    _autoNavTimer?.cancel();
    _telemetryTimer?.cancel();

    final isAuth = AuthState().isLoggedIn || FirebaseAuth.instance.currentUser != null;

    Navigator.of(context).pushReplacement(
      Cube3DPageRoute(
        page: isAuth ? const DashboardScreen() : const AuthScreen(),
      ),
    );
  }

  @override
  void dispose() {
    _telemetryTimer?.cancel();
    _autoNavTimer?.cancel();
    _pulseController.dispose();
    _radarController.dispose();
    _fadeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return Scaffold(
      backgroundColor: AppColors.surfaceContainerLowest,
      body: Stack(
        alignment: Alignment.center,
        children: [
          // Ambient Radial Light Flares
          Positioned(
            top: size.height * 0.35,
            child: Container(
              width: 320,
              height: 320,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    AppColors.secondaryContainer.withValues(alpha: 0.22),
                    AppColors.primary.withValues(alpha: 0.12),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),

          // Cybernetic Concentric Rings & Radar
          AnimatedBuilder(
            animation: Listenable.merge([_pulseController, _radarController]),
            builder: (context, child) {
              return CustomPaint(
                size: Size(size.width, size.height),
                painter: _RadarBackgroundPainter(
                  pulseProgress: _pulseController.value,
                  radarAngle: _radarController.value * 2 * math.pi,
                ),
              );
            },
          ),

          // Central Glassmorphic Brand Container
          FadeTransition(
            opacity: _fadeController,
            child: Center(
              child: GestureDetector(
                onTap: _navigateToNext,
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 24),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 28,
                    vertical: 24,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(24),
                    color: AppColors.surfaceContainer.withValues(alpha: 0.75),
                    border: Border.all(
                      color: AppColors.primary.withValues(alpha: 0.4),
                      width: 1.5,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.6),
                        blurRadius: 36,
                        offset: const Offset(0, 8),
                      ),
                      BoxShadow(
                        color: AppColors.primary.withValues(alpha: 0.18),
                        blurRadius: 32,
                        spreadRadius: -2,
                      ),
                    ],
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const ClassPulseLogo(size: 48, animated: true),
                      const SizedBox(height: 16),

                      // Wordmark + IOT Badge perfectly centered and scaled
                      FittedBox(
                        fit: BoxFit.scaleDown,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Text(
                              'ClassPulse',
                              style: AppTypography.displayLg(
                                color: Colors.white,
                                fontSize: 32,
                              ).copyWith(
                                letterSpacing: -0.5,
                                shadows: [
                                  Shadow(
                                    color: AppColors.primary
                                        .withValues(alpha: 0.8),
                                    blurRadius: 28,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 10),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8),
                                color: AppColors.primary.withValues(alpha: 0.16),
                                border: Border.all(
                                  color: AppColors.primary,
                                  width: 1.2,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: AppColors.primary
                                        .withValues(alpha: 0.45),
                                    blurRadius: 12,
                                  ),
                                ],
                              ),
                              child: Text(
                                'IOT',
                                style: AppTypography.labelSm(
                                  color: AppColors.primary,
                                ).copyWith(
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 1.5,
                                  fontSize: 11,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 14),

                      // Live Connected Node Beacon
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const PulsingBeacon(
                            size: 7,
                            color: AppColors.primary,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'LIVE CONNECTED NODE',
                            style: AppTypography.labelSm(
                              color: AppColors.primaryLight,
                            ).copyWith(
                              letterSpacing: 2.0,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // Bottom Telemetry Handshake Bar
          Positioned(
            bottom: 40,
            left: 20,
            right: 20,
            child: Column(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    color: AppColors.surfaceContainerLow.withValues(alpha: 0.85),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.08),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Row(
                          children: [
                            const PulsingBeacon(
                              size: 5,
                              color: AppColors.onlineMint,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: AnimatedSwitcher(
                                duration: const Duration(milliseconds: 250),
                                transitionBuilder: (child, animation) =>
                                    FadeTransition(opacity: animation, child: child),
                                layoutBuilder: (currentChild, previousChildren) {
                                  return currentChild ?? const SizedBox.shrink();
                                },
                                child: Text(
                                  _telemetryStages[_currentStage],
                                  key: ValueKey<int>(_currentStage),
                                  style: AppTypography.labelSm(
                                    color: AppColors.onSurfaceVariant,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        'ESP32 MESH',
                        style: AppTypography.labelSm(
                          color: AppColors.primary,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: _navigateToNext,
                  child: Text(
                    'TAP TO ENTER CONSOLE',
                    style: AppTypography.labelSm(
                      color: AppColors.outline,
                    ).copyWith(letterSpacing: 1.2),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RadarBackgroundPainter extends CustomPainter {
  final double pulseProgress;
  final double radarAngle;

  _RadarBackgroundPainter({
    required this.pulseProgress,
    required this.radarAngle,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);

    final linePaint = Paint()
      ..color = AppColors.primary.withValues(alpha: 0.12)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    // Expanding Pulse Rings
    for (int i = 0; i < 3; i++) {
      final ringProgress = (pulseProgress + (i * 0.33)) % 1.0;
      final ringRadius = 120.0 + (ringProgress * 180.0);
      final alpha = (1.0 - ringProgress) * 0.25;

      final ringPaint = Paint()
        ..color = AppColors.primary.withValues(alpha: alpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2;

      canvas.drawCircle(center, ringRadius, ringPaint);
    }

    // Static Technical Grid circles
    canvas.drawCircle(center, 90, linePaint);
    canvas.drawCircle(center, 180, linePaint);

    // Subtle radar sweep arm
    final sweepLength = 220.0;
    final endPoint = Offset(
      center.dx + sweepLength * math.cos(radarAngle),
      center.dy + sweepLength * math.sin(radarAngle),
    );

    final radarPaint = Paint()
      ..shader = RadialGradient(
        colors: [
          AppColors.primary.withValues(alpha: 0.25),
          Colors.transparent,
        ],
      ).createShader(Rect.fromCircle(center: center, radius: sweepLength))
      ..strokeWidth = 1.5;

    canvas.drawLine(center, endPoint, radarPaint);
  }

  @override
  bool shouldRepaint(covariant _RadarBackgroundPainter oldDelegate) {
    return oldDelegate.pulseProgress != pulseProgress ||
        oldDelegate.radarAngle != radarAngle;
  }
}

