import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_colors.dart';
import '../theme/app_typography.dart';
import '../theme/theme_controller.dart';
import 'theme_reveal.dart';

/// System / Light / Dark selector. Picking an option sweeps the new theme
/// out from the tapped segment.
class AppearancePicker extends StatelessWidget {
  const AppearancePicker({super.key});

  static const _options = <(ThemeMode, IconData, String)>[
    (ThemeMode.system, Icons.brightness_auto_rounded, 'System'),
    (ThemeMode.light, Icons.light_mode_rounded, 'Light'),
    (ThemeMode.dark, Icons.dark_mode_rounded, 'Dark'),
  ];

  /// One-line description of the current choice, for a caption above or
  /// below the picker.
  static String describe(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.system:
        return 'Following your phone\'s setting.';
      case ThemeMode.light:
        return 'Always use light mode.';
      case ThemeMode.dark:
        return 'Always use dark mode.';
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ThemeController(),
      builder: (context, _) {
        final mode = ThemeController().mode;
        final selected = _options.indexWhere((o) => o.$1 == mode);

        return Container(
          height: 46,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: AppColors.surfaceContainerHigh,
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final segment = constraints.maxWidth / _options.length;
              return Stack(
                children: [
                  AnimatedPositioned(
                    duration: const Duration(milliseconds: 320),
                    curve: Curves.easeOutCubic,
                    left: segment * selected,
                    top: 0,
                    bottom: 0,
                    width: segment,
                    child: Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        color: AppColors.surfaceContainerLow,
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.shadow(0.35),
                            blurRadius: 6,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      for (var i = 0; i < _options.length; i++)
                        Expanded(
                          child: Builder(
                            builder: (segmentContext) {
                              final isSelected = i == selected;
                              final color = isSelected
                                  ? AppColors.primary
                                  : AppColors.onSurfaceVariant;
                              return Semantics(
                                button: true,
                                selected: isSelected,
                                label: '${_options[i].$3} appearance',
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () {
                                    HapticFeedback.selectionClick();
                                    final box = segmentContext
                                        .findRenderObject() as RenderBox?;
                                    ThemeReveal.switchTo(
                                      _options[i].$1,
                                      origin: box?.localToGlobal(
                                        box.size.center(Offset.zero),
                                      ),
                                    );
                                  },
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(_options[i].$2,
                                          size: 16, color: color),
                                      const SizedBox(width: 6),
                                      Flexible(
                                        child: Text(
                                          _options[i].$3,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: AppTypography.labelMd(
                                            color: color,
                                          ).copyWith(fontSize: 12.5),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                    ],
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}
