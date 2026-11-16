import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_colors.dart';
import '../theme/app_typography.dart';

class CyberDropdownItem<T> {
  final T value;
  final String label;
  final String? subtitle;
  final IconData? icon;
  final Color? iconColor;

  const CyberDropdownItem({
    required this.value,
    required this.label,
    this.subtitle,
    this.icon,
    this.iconColor,
  });
}

/// A select field that opens its options in a bottom sheet — easier to hit
/// and to read on a phone than an inline dropdown menu.
class CyberDropdown<T> extends StatelessWidget {
  final T? value;
  final List<CyberDropdownItem<T>> items;
  final ValueChanged<T> onChanged;
  final String hint;
  final String? sheetTitle;
  final IconData? prefixIcon;

  const CyberDropdown({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.hint = 'Select Option',
    this.sheetTitle,
    this.prefixIcon,
  });

  void _openSelectionSheet(BuildContext context) {
    HapticFeedback.lightImpact();

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return Container(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.7,
          ),
          decoration: BoxDecoration(
            color: AppColors.sheet,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border(top: BorderSide(color: AppColors.overlay(0.08))),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 10),
                Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppColors.overlay(0.18),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          sheetTitle ?? hint,
                          style: AppTypography.headlineSm(
                            color: AppColors.onSurface,
                          ).copyWith(fontSize: 16, fontWeight: FontWeight.w600),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        '${items.length} options',
                        style: AppTypography.labelSm(color: AppColors.outline),
                      ),
                    ],
                  ),
                ),
                Divider(color: AppColors.overlay(0.08), height: 1),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: items.length,
                    itemBuilder: (ctx, idx) {
                      final item = items[idx];
                      final isSelected = item.value == value;

                      return Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 2,
                        ),
                        child: Material(
                          color: isSelected
                              ? AppColors.primary.withValues(alpha: 0.10)
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(12),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: () {
                              HapticFeedback.selectionClick();
                              Navigator.pop(ctx);
                              onChanged(item.value);
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 11,
                              ),
                              child: Row(
                                children: [
                                  if (item.icon != null) ...[
                                    Container(
                                      width: 34,
                                      height: 34,
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(10),
                                        color: isSelected
                                            ? AppColors.primary
                                                .withValues(alpha: 0.16)
                                            : AppColors.surfaceContainerHigh,
                                      ),
                                      child: Icon(
                                        item.icon,
                                        size: 17,
                                        color: isSelected
                                            ? AppColors.primary
                                            : (item.iconColor ??
                                                AppColors.onSurfaceVariant),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                  ],
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          item.label,
                                          style: AppTypography.bodyMd(
                                            color: isSelected
                                                ? AppColors.primary
                                                : AppColors.onSurface,
                                          ).copyWith(
                                            fontWeight: isSelected
                                                ? FontWeight.w600
                                                : FontWeight.w500,
                                            fontSize: 13.5,
                                          ),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        if (item.subtitle != null) ...[
                                          const SizedBox(height: 2),
                                          Text(
                                            item.subtitle!,
                                            style: AppTypography.bodySm(
                                              color: AppColors.outline,
                                            ).copyWith(fontSize: 11.5),
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  AnimatedOpacity(
                                    opacity: isSelected ? 1 : 0,
                                    duration:
                                        const Duration(milliseconds: 150),
                                    child: Icon(
                                      Icons.check_circle_rounded,
                                      size: 20,
                                      color: AppColors.primary,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    CyberDropdownItem<T>? selectedItem;
    for (final item in items) {
      if (item.value == value) {
        selectedItem = item;
        break;
      }
    }

    return Material(
      color: AppColors.surfaceContainerLowest,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _openSelectionSheet(context),
        child: Container(
          height: 50,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppColors.overlay(0.12)),
          ),
          child: Row(
            children: [
              if (prefixIcon != null || selectedItem?.icon != null) ...[
                Icon(
                  selectedItem?.icon ?? prefixIcon,
                  size: 18,
                  color: selectedItem != null
                      ? AppColors.primary
                      : AppColors.outline,
                ),
                const SizedBox(width: 10),
              ],
              Expanded(
                child: Text(
                  selectedItem?.label ?? hint,
                  style: AppTypography.bodyMd(
                    color: selectedItem != null
                        ? AppColors.onSurface
                        : AppColors.outline,
                  ).copyWith(fontSize: 13.5),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.expand_more_rounded,
                size: 20,
                color: AppColors.onSurfaceVariant,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
