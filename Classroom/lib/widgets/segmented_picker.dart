import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_colors.dart';
import '../theme/app_typography.dart';

/// A single-choice segmented control. Segments share the available width
/// equally, so it can never overflow its row, and the highlight slides
/// between options instead of jumping.
class SegmentedPicker<T> extends StatelessWidget {
  final List<T> values;
  final T? selected;
  final String Function(T value) labelOf;
  final ValueChanged<T> onChanged;
  final Color? accent;
  final double height;

  const SegmentedPicker({
    super.key,
    required this.values,
    required this.selected,
    required this.labelOf,
    required this.onChanged,
    this.accent,
    this.height = 34,
  });

  @override
  Widget build(BuildContext context) {
    final color = accent ?? AppColors.primary;
    final index = selected == null ? -1 : values.indexOf(selected as T);

    return Container(
      height: height,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: AppColors.surfaceContainerHigh,
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final segment = constraints.maxWidth / values.length;
          return Stack(
            children: [
              if (index >= 0)
                AnimatedPositioned(
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutCubic,
                  left: segment * index,
                  top: 0,
                  bottom: 0,
                  width: segment,
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(8),
                      color: color,
                    ),
                  ),
                ),
              Row(
                children: [
                  for (var i = 0; i < values.length; i++)
                    Expanded(
                      child: Semantics(
                        button: true,
                        selected: i == index,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () {
                            if (i == index) return;
                            HapticFeedback.selectionClick();
                            onChanged(values[i]);
                          },
                          child: Center(
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 2),
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: AnimatedDefaultTextStyle(
                                  duration: const Duration(milliseconds: 200),
                                  style: AppTypography.labelSm(
                                    color: i == index
                                        ? (color == AppColors.primary
                                            ? AppColors.onPrimary
                                            : AppColors.onAccent)
                                        : AppColors.onSurfaceVariant,
                                  ).copyWith(
                                    fontSize: 12,
                                    fontWeight: i == index
                                        ? FontWeight.w700
                                        : FontWeight.w500,
                                  ),
                                  child: Text(labelOf(values[i]), maxLines: 1),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}
