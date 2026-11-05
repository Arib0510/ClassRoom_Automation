import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_colors.dart';
import '../theme/app_typography.dart';
import 'pulsing_beacon.dart';

class CyberPopup {
  static Future<T?> show<T>(
    BuildContext context, {
    required String title,
    String? subtitle,
    Widget? content,
    IconData icon = Icons.security,
    Color accentColor = AppColors.primary,
    String confirmText = 'CONFIRM',
    VoidCallback? onConfirm,
    String cancelText = 'CANCEL',
    VoidCallback? onCancel,
    bool isDestructive = false,
  }) {
    HapticFeedback.mediumImpact();

    return showGeneralDialog<T>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'CyberPopup',
      barrierColor: Colors.black.withValues(alpha: 0.72),
      transitionDuration: const Duration(milliseconds: 260),
      transitionBuilder: (context, anim1, anim2, child) {
        final curved = CurvedAnimation(parent: anim1, curve: Curves.easeOutBack);
        return ScaleTransition(
          scale: Tween<double>(begin: 0.92, end: 1.0).animate(curved),
          child: FadeTransition(
            opacity: anim1,
            child: child,
          ),
        );
      },
      pageBuilder: (context, anim1, anim2) {
        return Center(
          child: Material(
            color: Colors.transparent,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
                  child: Container(
                    padding: const EdgeInsets.all(22),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0A0F1D).withValues(alpha: 0.94),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: (isDestructive ? AppColors.error : accentColor).withValues(alpha: 0.45),
                        width: 1.5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.7),
                          blurRadius: 36,
                          offset: const Offset(0, 12),
                        ),
                        BoxShadow(
                          color: (isDestructive ? AppColors.error : accentColor).withValues(alpha: 0.22),
                          blurRadius: 28,
                          spreadRadius: -4,
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Header with Icon & Beacon
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.all(8),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(10),
                                color: (isDestructive ? AppColors.error : accentColor).withValues(alpha: 0.15),
                                border: Border.all(
                                  color: (isDestructive ? AppColors.error : accentColor).withValues(alpha: 0.35),
                                ),
                              ),
                              child: Icon(
                                icon,
                                size: 20,
                                color: isDestructive ? AppColors.error : accentColor,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      PulsingBeacon(
                                        size: 6,
                                        color: isDestructive ? AppColors.error : accentColor,
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        'SYSTEM DIALOG // SECURE',
                                        style: AppTypography.labelSm(
                                          color: isDestructive ? AppColors.error : accentColor,
                                        ).copyWith(fontSize: 8.5, letterSpacing: 1.2, fontWeight: FontWeight.bold),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    title,
                                    style: AppTypography.headlineSm(
                                      color: AppColors.onSurface,
                                    ).copyWith(fontSize: 16, fontWeight: FontWeight.bold),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),

                        if (subtitle != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            subtitle,
                            style: AppTypography.bodySm(color: AppColors.onSurfaceVariant),
                          ),
                        ],

                        if (content != null) ...[
                          const SizedBox(height: 16),
                          content,
                        ],

                        const SizedBox(height: 22),

                        // Actions Row
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                style: OutlinedButton.styleFrom(
                                  backgroundColor: AppColors.surfaceContainerLowest,
                                  foregroundColor: AppColors.outline,
                                  side: BorderSide(
                                    color: Colors.white.withValues(alpha: 0.12),
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  padding: const EdgeInsets.symmetric(vertical: 11),
                                ),
                                onPressed: () {
                                  Navigator.pop(context);
                                  onCancel?.call();
                                },
                                child: Text(
                                  cancelText,
                                  style: AppTypography.labelMd(color: AppColors.outline).copyWith(
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: isDestructive ? AppColors.error : accentColor,
                                  foregroundColor: isDestructive ? Colors.white : AppColors.surfaceContainerLowest,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  padding: const EdgeInsets.symmetric(vertical: 11),
                                  elevation: 4,
                                  shadowColor: (isDestructive ? AppColors.error : accentColor).withValues(alpha: 0.4),
                                ),
                                onPressed: () {
                                  onConfirm?.call();
                                },
                                child: Text(
                                  confirmText,
                                  style: AppTypography.labelMd(
                                    color: isDestructive ? Colors.white : AppColors.surfaceContainerLowest,
                                  ).copyWith(fontWeight: FontWeight.bold),
                                ),
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
          ),
        );
      },
    );
  }
}
