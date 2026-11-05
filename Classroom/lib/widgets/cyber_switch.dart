import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_colors.dart';

class CyberSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  final double width;
  final double height;

  const CyberSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.width = 44.0,
    this.height = 26.0,
  });

  @override
  Widget build(BuildContext context) {
    final thumbSize = height - 4.0;

    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onChanged(!value);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
        width: width,
        height: height,
        padding: const EdgeInsets.all(2.0),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(height / 2),
          color: value ? AppColors.primary : AppColors.surfaceContainerHigh,
          border: Border.all(
            color: value
                ? AppColors.primary
                : Colors.white.withValues(alpha: 0.12),
            width: 1.0,
          ),
          boxShadow: value
              ? [
                  BoxShadow(
                    color: AppColors.primary.withValues(alpha: 0.35),
                    blurRadius: 8,
                    spreadRadius: -1,
                  ),
                ]
              : null,
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOutCubic,
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: thumbSize,
            height: thumbSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: value
                  ? AppColors.surfaceContainerLowest
                  : const Color(0xFF474C5B),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 3,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
            child: Center(
              child: Icon(
                value ? Icons.check : Icons.close,
                size: thumbSize * 0.65,
                color: value ? AppColors.primary : AppColors.onSurfaceVariant,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

