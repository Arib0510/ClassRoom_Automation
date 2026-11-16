import 'dart:math' as math;
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:open_filex/open_filex.dart';
import '../services/app_update_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_typography.dart';

enum UpdateStep {
  checking,
  updateAvailable,
  downloading,
  readyToInstall,
  upToDate,
  error,
}

class CyberUpdateDialog extends StatefulWidget {
  final VoidCallback? onDismiss;

  const CyberUpdateDialog({
    super.key,
    this.onDismiss,
  });

  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierColor: AppColors.scrim,
      builder: (context) => const CyberUpdateDialog(),
    );
  }

  @override
  State<CyberUpdateDialog> createState() => _CyberUpdateDialogState();
}

class _CyberUpdateDialogState extends State<CyberUpdateDialog>
    with TickerProviderStateMixin {
  final AppUpdateService _updateService = AppUpdateService();

  UpdateStep _step = UpdateStep.checking;
  AppReleaseInfo? _releaseInfo;
  String _errorMessage = '';

  // Download state
  double _downloadProgress = 0.0;
  int _receivedBytes = 0;
  int _totalBytes = 0;
  String? _downloadedFilePath;
  CancelToken? _cancelToken;

  // Animations
  late AnimationController _radarController;
  late AnimationController _pulseController;
  late AnimationController _shimmerController;

  @override
  void initState() {
    super.initState();
    _radarController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

    _shimmerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();

    _startCheck();
  }

  @override
  void dispose() {
    _cancelToken?.cancel();
    _radarController.dispose();
    _pulseController.dispose();
    _shimmerController.dispose();
    super.dispose();
  }

  Future<void> _startCheck() async {
    setState(() {
      _step = UpdateStep.checking;
      _errorMessage = '';
    });

    try {
      // Minimum duration for scanner animation visual polish
      final results = await Future.wait([
        _updateService.checkForUpdate(),
        Future.delayed(const Duration(milliseconds: 1400)),
      ]);

      if (!mounted) return;
      final release = results[0] as AppReleaseInfo;
      setState(() {
        _releaseInfo = release;
        if (release.isUpdateAvailable && release.apkUrl != null) {
          _step = UpdateStep.updateAvailable;
        } else {
          _step = UpdateStep.upToDate;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _errorMessage = e is DioException
            ? (e.message ?? 'Network connection failed')
            : e.toString();
        _step = UpdateStep.error;
      });
    }
  }

  Future<void> _startDownload() async {
    if (_releaseInfo?.apkUrl == null) return;

    setState(() {
      _step = UpdateStep.downloading;
      _downloadProgress = 0.0;
      _receivedBytes = 0;
      _totalBytes = _releaseInfo!.apkSize;
      _cancelToken = CancelToken();
    });

    try {
      final file = await _updateService.downloadApk(
        downloadUrl: _releaseInfo!.apkUrl!,
        cancelToken: _cancelToken,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _receivedBytes = received;
            _totalBytes = total > 0 ? total : _releaseInfo!.apkSize;
            if (_totalBytes > 0) {
              _downloadProgress = (_receivedBytes / _totalBytes).clamp(0.0, 1.0);
            }
          });
        },
      );

      if (!mounted) return;
      setState(() {
        _downloadedFilePath = file.path;
        _step = UpdateStep.readyToInstall;
      });

      // Auto trigger package installer
      await _installApk();
    } catch (e) {
      if (!mounted) return;
      if (e is DioException && CancelToken.isCancel(e)) {
        setState(() {
          _step = UpdateStep.updateAvailable;
        });
        return;
      }
      setState(() {
        _errorMessage = 'Download failed: ${e.toString()}';
        _step = UpdateStep.error;
      });
    }
  }

  Future<void> _installApk() async {
    if (_downloadedFilePath == null) return;
    try {
      final result = await _updateService.installApk(_downloadedFilePath!);
      if (result.type != ResultType.done && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: AppColors.surfaceContainerHigh,
            content: Text(
              'Installer launched: ${result.message}',
              style: AppTypography.bodySm(color: AppColors.onSurface),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = 'Install trigger failed: $e';
        });
      }
    }
  }

  void _cancelDownload() {
    _cancelToken?.cancel('User canceled');
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      child: Container(
        width: double.infinity,
        constraints: const BoxConstraints(maxWidth: 440),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          color: AppColors.surfaceContainerHigh,
          border: Border.all(
            color: _getAccentColor().withValues(alpha: 0.5),
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: _getAccentColor().withValues(alpha: 0.25),
              blurRadius: 28,
              spreadRadius: 2,
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildCyberHeader(),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                child: _buildBodyContent(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Color _getAccentColor() {
    switch (_step) {
      case UpdateStep.checking:
        return AppColors.primary;
      case UpdateStep.updateAvailable:
        return AppColors.onlineMint;
      case UpdateStep.downloading:
        return AppColors.primary;
      case UpdateStep.readyToInstall:
        return AppColors.onlineMint;
      case UpdateStep.upToDate:
        return AppColors.secondaryLight;
      case UpdateStep.error:
        return AppColors.error;
    }
  }

  Widget _buildCyberHeader() {
    final accent = _getAccentColor();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerLowest,
        border: Border(
          bottom: BorderSide(
            color: accent.withValues(alpha: 0.25),
          ),
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: accent.withValues(alpha: 0.15),
              border: Border.all(color: accent.withValues(alpha: 0.4)),
            ),
            child: Icon(
              Icons.system_update_rounded,
              color: accent,
              size: 16,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'OTA SYSTEM UPDATER',
                  style: AppTypography.headlineSm(color: AppColors.onSurface).copyWith(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                  ),
                ),
                Text(
                  'GitHub Core / Arib0510',
                  style: AppTypography.labelSm(color: AppColors.outline).copyWith(
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
          if (_step != UpdateStep.downloading)
            IconButton(
              icon: Icon(Icons.close_rounded, size: 20, color: AppColors.outline),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
              splashRadius: 20,
              onPressed: () {
                widget.onDismiss?.call();
                Navigator.of(context).pop();
              },
            ),
        ],
      ),
    );
  }

  Widget _buildBodyContent() {
    switch (_step) {
      case UpdateStep.checking:
        return _buildCheckingView();
      case UpdateStep.updateAvailable:
        return _buildUpdateAvailableView();
      case UpdateStep.downloading:
        return _buildDownloadingView();
      case UpdateStep.readyToInstall:
        return _buildReadyToInstallView();
      case UpdateStep.upToDate:
        return _buildUpToDateView();
      case UpdateStep.error:
        return _buildErrorView();
    }
  }

  // 1. CHECKING VIEW WITH CYBER RADAR
  Widget _buildCheckingView() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 16),
        SizedBox(
          width: 140,
          height: 140,
          child: AnimatedBuilder(
            animation: _radarController,
            builder: (context, child) {
              return CustomPaint(
                painter: _CyberRadarPainter(
                  rotation: _radarController.value * 2 * math.pi,
                  accentColor: AppColors.primary,
                ),
                child: Center(
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.primary.withValues(alpha: 0.15),
                      border: Border.all(color: AppColors.primary.withValues(alpha: 0.6)),
                    ),
                    child: Icon(
                      Icons.cloud_sync_rounded,
                      color: AppColors.primary,
                      size: 24,
                    ),
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 24),
        Text(
          'CONNECTING TO REPOSITORY',
          style: AppTypography.headlineSm(color: AppColors.onSurface).copyWith(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.0,
          ),
        ),
        const SizedBox(height: 6),
        AnimatedBuilder(
          animation: _pulseController,
          builder: (context, child) {
            return Opacity(
              opacity: 0.5 + (_pulseController.value * 0.5),
              child: Text(
                'Querying GitHub releases for new APK builds...',
                textAlign: TextAlign.center,
                style: AppTypography.bodySm(color: AppColors.onSurfaceVariant),
              ),
            );
          },
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  // 2. UPDATE AVAILABLE VIEW
  Widget _buildUpdateAvailableView() {
    final release = _releaseInfo!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(20),
              color: AppColors.onlineMint.withValues(alpha: 0.15),
              border: Border.all(color: AppColors.onlineMint.withValues(alpha: 0.6)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.new_releases_rounded, color: AppColors.onlineMint, size: 16),
                const SizedBox(width: 8),
                Text(
                  'NEW UPDATE DISCOVERED',
                  style: AppTypography.labelSm(color: AppColors.onlineMint).copyWith(
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.0,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),

        // Version comparison box
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: AppColors.surfaceContainerLowest,
            border: Border.all(color: AppColors.overlay(0.08)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('CURRENT BUILD', style: AppTypography.labelSm(color: AppColors.outline).copyWith(fontSize: 10)),
                    const SizedBox(height: 2),
                    Text(
                      'v${release.currentVersion}',
                      style: AppTypography.bodyMd(color: AppColors.onSurfaceVariant).copyWith(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
              Icon(Icons.arrow_forward_rounded, color: AppColors.onlineMint, size: 18),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text('TARGET RELEASE', style: AppTypography.labelSm(color: AppColors.onlineMint).copyWith(fontSize: 10)),
                    const SizedBox(height: 2),
                    Text(
                      release.tagName,
                      style: AppTypography.bodyMd(color: AppColors.onlineMint).copyWith(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 12),

        // Release details & Notes
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(child: Text('Changelog & Notes', style: AppTypography.bodySm(color: AppColors.onSurface).copyWith(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis,)),
            if (release.apkSize > 0)
              Text(
                'Size: ${release.formattedApkSize}',
                style: AppTypography.labelSm(color: AppColors.secondaryLight),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Container(
          height: 100,
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            color: AppColors.surfaceContainerLowest,
            border: Border.all(color: AppColors.secondary.withValues(alpha: 0.2)),
          ),
          child: SingleChildScrollView(
            child: Text(
              release.releaseNotes.isEmpty ? 'General maintenance and performance upgrades.' : release.releaseNotes,
              style: AppTypography.bodySm(color: AppColors.onSurfaceVariant).copyWith(fontSize: 12, height: 1.4),
            ),
          ),
        ),

        const SizedBox(height: 18),

        // Action Buttons
        SizedBox(
          width: double.infinity,
          height: 48,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.onlineMint,
              foregroundColor: AppColors.surfaceContainerLowest,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
              elevation: 4,
            ),
            onPressed: _startDownload,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.download_rounded, size: 18),
                const SizedBox(width: 8),
                Text(
                  'DOWNLOAD & INSTALL APK',
                  style: AppTypography.bodyMd().copyWith(
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.8,
                    color: AppColors.surfaceContainerLowest,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // 3. DOWNLOADING VIEW WITH CYBER PROGRESS BAR
  Widget _buildDownloadingView() {
    final percent = (_downloadProgress * 100).toInt();
    final downloadedMb = (_receivedBytes / (1024 * 1024)).toStringAsFixed(1);
    final totalMb = _totalBytes > 0
        ? (_totalBytes / (1024 * 1024)).toStringAsFixed(1)
        : '?';

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 12),
        // Radial / Circular download glow
        Stack(
          alignment: Alignment.center,
          children: [
            SizedBox(
              width: 90,
              height: 90,
              child: CircularProgressIndicator(
                value: _downloadProgress > 0 ? _downloadProgress : null,
                strokeWidth: 6,
                backgroundColor: AppColors.overlay(0.08),
                valueColor: AlwaysStoppedAnimation<Color>(AppColors.primary),
              ),
            ),
            Text(
              '$percent%',
              style: AppTypography.headlineSm(color: AppColors.primary).copyWith(
                fontWeight: FontWeight.bold,
                fontSize: 18,
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Text(
          'DOWNLOADING BINARY ARCHIVE',
          style: AppTypography.headlineSm(color: AppColors.onSurface).copyWith(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.0,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '$downloadedMb MB of $totalMb MB received',
          style: AppTypography.bodySm(color: AppColors.onSurfaceVariant),
        ),

        const SizedBox(height: 18),

        // Cyberpunk Shimmer Linear Progress Bar
        Container(
          height: 12,
          width: double.infinity,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            color: AppColors.surfaceContainerLowest,
            border: Border.all(color: AppColors.primary.withValues(alpha: 0.3)),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final fillWidth = constraints.maxWidth * _downloadProgress;
              return Stack(
                children: [
                  Container(
                    width: fillWidth,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(6),
                      gradient: LinearGradient(
                        colors: [AppColors.secondary, AppColors.primary],
                      ),
                    ),
                  ),
                  AnimatedBuilder(
                    animation: _shimmerController,
                    builder: (context, child) {
                      final shimmerPos = constraints.maxWidth * _shimmerController.value;
                      return Positioned(
                        left: shimmerPos - 30,
                        top: 0,
                        bottom: 0,
                        width: 40,
                        child: Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                Colors.transparent,
                                AppColors.overlay(0.4),
                                Colors.transparent,
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ],
              );
            },
          ),
        ),

        const SizedBox(height: 20),

        OutlinedButton(
          style: OutlinedButton.styleFrom(
            foregroundColor: AppColors.outline,
            side: BorderSide(color: AppColors.outline.withValues(alpha: 0.3)),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          onPressed: _cancelDownload,
          child: const Text('Cancel Download'),
        ),
      ],
    );
  }

  // 4. READY TO INSTALL VIEW
  Widget _buildReadyToInstallView() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 12),
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.onlineMint.withValues(alpha: 0.15),
            border: Border.all(color: AppColors.onlineMint.withValues(alpha: 0.7), width: 2),
            boxShadow: [
              BoxShadow(
                color: AppColors.onlineMint.withValues(alpha: 0.3),
                blurRadius: 18,
                spreadRadius: 2,
              ),
            ],
          ),
          child: Icon(
            Icons.task_alt_rounded,
            color: AppColors.onlineMint,
            size: 40,
          ),
        ),
        const SizedBox(height: 18),
        Text(
          'PACKAGE READY TO INSTALL',
          style: AppTypography.headlineSm(color: AppColors.onSurface).copyWith(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.0,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          'APK payload downloaded and verified. The Android Package Installer should open automatically.',
          textAlign: TextAlign.center,
          style: AppTypography.bodySm(color: AppColors.onSurfaceVariant),
        ),
        const SizedBox(height: 20),

        SizedBox(
          width: double.infinity,
          height: 48,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.onlineMint,
              foregroundColor: AppColors.surfaceContainerLowest,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
            ),
            onPressed: _installApk,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.install_mobile_rounded, size: 20),
                const SizedBox(width: 8),
                Text(
                  'LAUNCH PACKAGE INSTALLER',
                  style: AppTypography.bodyMd().copyWith(
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.8,
                    color: AppColors.surfaceContainerLowest,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // 5. UP TO DATE VIEW
  Widget _buildUpToDateView() {
    final release = _releaseInfo;
    final isNoReleases = release?.noReleaseFound ?? false;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 12),
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.primary.withValues(alpha: 0.12),
            border: Border.all(color: AppColors.primary.withValues(alpha: 0.5), width: 1.5),
            boxShadow: [
              BoxShadow(
                color: AppColors.primary.withValues(alpha: 0.2),
                blurRadius: 16,
              ),
            ],
          ),
          child: Icon(
            Icons.verified_user_rounded,
            color: AppColors.primary,
            size: 38,
          ),
        ),
        const SizedBox(height: 18),
        Text(
          'SYSTEM IS UP TO DATE',
          style: AppTypography.headlineSm(color: AppColors.onSurface).copyWith(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.0,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          isNoReleases
              ? 'No newer public releases found on GitHub repository. You are running local build v${release?.currentVersion ?? "1.0.0"}.'
              : 'You are running the latest version v${release?.currentVersion ?? ""}. No OTA updates pending.',
          textAlign: TextAlign.center,
          style: AppTypography.bodySm(color: AppColors.onSurfaceVariant),
        ),
        const SizedBox(height: 20),

        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.outline,
                  side: BorderSide(color: AppColors.outline.withValues(alpha: 0.3)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Dismiss'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: AppColors.surfaceContainerLowest,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () {
                  if (_releaseInfo == null || _releaseInfo!.apkUrl == null) {
                    _releaseInfo = AppReleaseInfo(
                      tagName: release?.tagName ?? 'v1.0.4+5',
                      cleanVersion: release?.cleanVersion ?? '1.0.4',
                      buildNumber: release?.buildNumber ?? 5,
                      releaseName: 'ClassPulse Latest Build',
                      releaseNotes: 'OTA distribution build from GitHub repository.',
                      apkUrl: AppUpdateService.directApkUrl,
                      apkFileName: 'app-release.apk',
                      apkSize: 56709983,
                      isUpdateAvailable: true,
                      currentVersion: release?.currentVersion ?? '1.0.4+5',
                    );
                  }
                  _startDownload();
                },
                child: const Text('Reinstall APK', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // 6. ERROR VIEW
  Widget _buildErrorView() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 12),
        Container(
          width: 64,
          height: 64,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: AppColors.error.withValues(alpha: 0.15),
            border: Border.all(color: AppColors.error.withValues(alpha: 0.5), width: 1.5),
          ),
          child: Icon(
            Icons.cloud_off_rounded,
            color: AppColors.error,
            size: 32,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'UPDATE CHECK FAILED',
          style: AppTypography.headlineSm(color: AppColors.error).copyWith(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.8,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          _errorMessage.isEmpty ? 'Failed to fetch release payload from GitHub.' : _errorMessage,
          textAlign: TextAlign.center,
          style: AppTypography.bodySm(color: AppColors.onSurfaceVariant),
        ),
        const SizedBox(height: 20),

        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.outline,
                  side: BorderSide(color: AppColors.outline.withValues(alpha: 0.3)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: AppColors.surfaceContainerLowest,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: _startCheck,
                child: const Text('Retry Scan'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

/// Custom Cyber Radar Painter for Sci-Fi Scanning Animation
class _CyberRadarPainter extends CustomPainter {
  final double rotation;
  final Color accentColor;

  _CyberRadarPainter({
    required this.rotation,
    required this.accentColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;

    // Concentric grid circles
    final circlePaint = Paint()
      ..color = accentColor.withValues(alpha: 0.18)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    canvas.drawCircle(center, radius, circlePaint);
    canvas.drawCircle(center, radius * 0.70, circlePaint);
    canvas.drawCircle(center, radius * 0.40, circlePaint);

    // Crosshairs
    final linePaint = Paint()
      ..color = accentColor.withValues(alpha: 0.12)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    canvas.drawLine(Offset(center.dx - radius, center.dy), Offset(center.dx + radius, center.dy), linePaint);
    canvas.drawLine(Offset(center.dx, center.dy - radius), Offset(center.dx, center.dy + radius), linePaint);

    // Rotating Radar Sweep Arc
    final sweepRect = Rect.fromCircle(center: center, radius: radius);
    final sweepGradient = SweepGradient(
      startAngle: 0.0,
      endAngle: math.pi * 2,
      transform: GradientRotation(rotation),
      colors: [
        accentColor.withValues(alpha: 0.0),
        accentColor.withValues(alpha: 0.0),
        accentColor.withValues(alpha: 0.08),
        accentColor.withValues(alpha: 0.35),
      ],
      stops: const [0.0, 0.70, 0.88, 1.0],
    );

    final sweepPaint = Paint()
      ..shader = sweepGradient.createShader(sweepRect)
      ..style = PaintingStyle.fill;

    canvas.drawCircle(center, radius, sweepPaint);

    // Sweep leading edge line
    final sweepLineEnd = Offset(
      center.dx + radius * math.cos(rotation),
      center.dy + radius * math.sin(rotation),
    );
    final sweepLinePaint = Paint()
      ..color = accentColor.withValues(alpha: 0.8)
      ..strokeWidth = 1.8;
    canvas.drawLine(center, sweepLineEnd, sweepLinePaint);
  }

  @override
  bool shouldRepaint(covariant _CyberRadarPainter oldDelegate) {
    return oldDelegate.rotation != rotation;
  }
}
