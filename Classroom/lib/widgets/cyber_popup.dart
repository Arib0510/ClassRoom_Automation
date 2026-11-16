import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_colors.dart';
import '../theme/app_typography.dart';

/// The app's confirmation dialog: an icon, a title, optional supporting text
/// or custom content, and a cancel / confirm pair.
///
/// [onConfirm] is responsible for closing the dialog (callers pop the
/// navigator themselves so they can run async work first).
class CyberPopup {
  static Future<T?> show<T>(
    BuildContext context, {
    required String title,
    String? subtitle,
    Widget? content,
    IconData icon = Icons.security,
    Color? accentColor,
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
      barrierLabel: 'Dismiss',
      barrierColor: AppColors.scrim,
      transitionDuration: const Duration(milliseconds: 300),
      transitionBuilder: (context, anim1, anim2, child) {
        final curved = CurvedAnimation(
          parent: anim1,
          curve: Curves.easeOutBack,
          reverseCurve: Curves.easeIn,
        );
        return FadeTransition(
          opacity: CurvedAnimation(parent: anim1, curve: Curves.easeOut),
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0, 0.04),
              end: Offset.zero,
            ).animate(curved),
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.92, end: 1.0).animate(curved),
              child: child,
            ),
          ),
        );
      },
      pageBuilder: (context, anim1, anim2) {
        final accent =
            isDestructive ? AppColors.error : (accentColor ?? AppColors.primary);
        final onAccent =
            isDestructive ? AppColors.onError : AppColors.onPrimary;

        return SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
              child: Material(
                color: Colors.transparent,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(22, 22, 22, 18),
                    decoration: BoxDecoration(
                      color: AppColors.sheet,
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(color: AppColors.overlay(0.08)),
                      boxShadow: [
                        BoxShadow(
                          color: AppColors.shadow(0.6),
                          blurRadius: 40,
                          spreadRadius: -8,
                          offset: const Offset(0, 18),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Container(
                              width: 42,
                              height: 42,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(13),
                                color: accent.withValues(alpha: 0.14),
                              ),
                              child: Icon(icon, size: 22, color: accent),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Text(
                                title,
                                style: AppTypography.headlineSm(
                                  color: AppColors.onSurface,
                                ).copyWith(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w600,
                                ),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        if (subtitle != null) ...[
                          const SizedBox(height: 14),
                          Text(
                            subtitle,
                            style: AppTypography.bodySm(
                              color: AppColors.onSurfaceVariant,
                            ).copyWith(fontSize: 13, height: 1.45),
                          ),
                        ],
                        if (content != null) ...[
                          const SizedBox(height: 16),
                          content,
                        ],
                        const SizedBox(height: 22),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                style: OutlinedButton.styleFrom(
                                  foregroundColor: AppColors.onSurfaceVariant,
                                  side: BorderSide(
                                    color: AppColors.outlineVariant,
                                  ),
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 13),
                                ),
                                onPressed: () {
                                  Navigator.pop(context);
                                  onCancel?.call();
                                },
                                child: Text(
                                  cancelText,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTypography.labelMd(
                                    color: AppColors.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: ElevatedButton(
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: accent,
                                  foregroundColor: onAccent,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(12),
                                  ),
                                  padding:
                                      const EdgeInsets.symmetric(vertical: 13),
                                  elevation: 0,
                                ),
                                onPressed: () {
                                  onConfirm?.call();
                                },
                                child: Text(
                                  confirmText,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTypography.labelMd(color: onAccent)
                                      .copyWith(fontWeight: FontWeight.w700),
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
