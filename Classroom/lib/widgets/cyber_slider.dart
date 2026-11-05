import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_colors.dart';
import '../theme/app_typography.dart';

class CyberSlider extends StatefulWidget {
  final double value; // 0..100
  final ValueChanged<double> onChanged;
  final String label;
  final String unit;
  final int maxMetric;

  const CyberSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.label = 'DIM:',
    this.unit = 'LM',
    this.maxMetric = 1400,
  });

  @override
  State<CyberSlider> createState() => _CyberSliderState();
}

class _CyberSliderState extends State<CyberSlider> {
  void _updateValue(Offset localPos, double width) {
    if (width <= 0) return;
    final clampedX = localPos.dx.clamp(0.0, width);
    final ratio = clampedX / width;
    final newValue = (ratio * 100.0).clamp(0.0, 100.0);
    HapticFeedback.selectionClick();
    widget.onChanged(newValue);
  }

  @override
  Widget build(BuildContext context) {
    final metricValue = ((widget.value / 100.0) * widget.maxMetric).round();

    return Row(
      children: [
        Text(
          widget.label,
          style: AppTypography.labelSm(color: AppColors.onSurfaceVariant),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final trackWidth = constraints.maxWidth;
              final fillWidth = (widget.value / 100.0) * trackWidth;

              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragUpdate: (details) {
                  _updateValue(details.localPosition, trackWidth);
                },
                onTapDown: (details) {
                  _updateValue(details.localPosition, trackWidth);
                },
                child: Container(
                  height: 28,
                  decoration: BoxDecoration(
                    color: AppColors.surfaceContainerLowest,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.08),
                    ),
                  ),
                  child: Stack(
                    alignment: Alignment.centerLeft,
                    children: [
                      // Progressive Glowing Fill
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 60),
                        width: fillWidth,
                        height: double.infinity,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.horizontal(
                            left: const Radius.circular(5),
                            right: Radius.circular(widget.value >= 98 ? 5 : 2),
                          ),
                          gradient: const LinearGradient(
                            colors: [
                              AppColors.secondaryContainer,
                              AppColors.primary,
                            ],
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: AppColors.primary.withValues(alpha: 0.3),
                              blurRadius: 8,
                            ),
                          ],
                        ),
                      ),
                      // Tactile Grip line
                      Positioned(
                        left: (fillWidth - 3).clamp(0.0, trackWidth - 3),
                        top: 2,
                        bottom: 2,
                        child: Container(
                          width: 3,
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(1.5),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.5),
                                blurRadius: 2,
                              ),
                            ],
                          ),
                        ),
                      ),
                      // Metric readout (positioned cleanly on the right)
                      Positioned(
                        right: 8,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.brightness_medium,
                              size: 11,
                              color: widget.value > 50
                                  ? AppColors.surfaceContainerLowest
                                  : AppColors.onSurfaceVariant,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '$metricValue ${widget.unit}',
                              style: AppTypography.labelSm(
                                color: widget.value > 50
                                    ? AppColors.surfaceContainerLowest
                                    : AppColors.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 36,
          child: Text(
            '${widget.value.round()}%',
            textAlign: TextAlign.right,
            style: AppTypography.labelLg(color: AppColors.primary),
          ),
        ),
      ],
    );
  }
}

