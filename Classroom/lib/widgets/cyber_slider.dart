import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_colors.dart';
import '../theme/app_typography.dart';

/// A 0–100 level slider with its label on the left and the current
/// percentage on the right. Drag anywhere on the track or tap to jump.
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
  bool _dragging = false;
  int _lastHapticStep = -1;

  void _updateValue(Offset localPos, double width) {
    if (width <= 0) return;
    final ratio = (localPos.dx / width).clamp(0.0, 1.0);
    final newValue = ratio * 100.0;

    // One tick per 5% rather than one per pixel of drag.
    final step = (newValue / 5).round();
    if (step != _lastHapticStep) {
      _lastHapticStep = step;
      HapticFeedback.selectionClick();
    }
    widget.onChanged(newValue);
  }

  @override
  Widget build(BuildContext context) {
    final value = widget.value.clamp(0.0, 100.0);
    final label = widget.label.replaceAll(':', '').trim();

    return Row(
      children: [
        if (label.isNotEmpty) ...[
          Text(
            label,
            style: AppTypography.labelSm(color: AppColors.onSurfaceVariant),
          ),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final trackWidth = constraints.maxWidth;
              const thumb = 18.0;
              final thumbLeft =
                  ((value / 100.0) * (trackWidth - thumb)).clamp(0.0, trackWidth);
              final fillWidth = thumbLeft + thumb / 2;

              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onHorizontalDragStart: (d) {
                  setState(() => _dragging = true);
                  _updateValue(d.localPosition, trackWidth);
                },
                onHorizontalDragUpdate: (d) =>
                    _updateValue(d.localPosition, trackWidth),
                onHorizontalDragEnd: (_) => setState(() => _dragging = false),
                onHorizontalDragCancel: () => setState(() => _dragging = false),
                onTapDown: (d) => _updateValue(d.localPosition, trackWidth),
                child: SizedBox(
                  height: 30,
                  child: Stack(
                    alignment: Alignment.centerLeft,
                    clipBehavior: Clip.none,
                    children: [
                      // Track
                      Container(
                        height: 8,
                        decoration: BoxDecoration(
                          color: AppColors.surfaceContainerHigh,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                      // Fill
                      Container(
                        width: fillWidth,
                        height: 8,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(4),
                          gradient: LinearGradient(
                            colors: [
                              AppColors.secondary,
                              AppColors.primary,
                            ],
                          ),
                        ),
                      ),
                      // Thumb
                      Positioned(
                        left: thumbLeft,
                        child: AnimatedScale(
                          scale: _dragging ? 1.25 : 1.0,
                          duration: const Duration(milliseconds: 140),
                          curve: Curves.easeOut,
                          child: Container(
                            width: thumb,
                            height: thumb,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.white,
                              border: Border.all(
                                color: AppColors.primary,
                                width: 2.5,
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: AppColors.primary.withValues(
                                    alpha: _dragging ? 0.45 : 0.25,
                                  ),
                                  blurRadius: _dragging ? 14 : 6,
                                ),
                              ],
                            ),
                          ),
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
          width: 40,
          child: Text(
            '${value.round()}%',
            textAlign: TextAlign.right,
            style: AppTypography.labelLg(color: AppColors.primary),
          ),
        ),
      ],
    );
  }
}
