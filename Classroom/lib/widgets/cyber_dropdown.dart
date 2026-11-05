import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_colors.dart';
import '../theme/app_typography.dart';
import 'pulsing_beacon.dart';

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
        return ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: Container(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(ctx).size.height * 0.65,
              ),
              decoration: BoxDecoration(
                color: const Color(0xFF0C1322).withValues(alpha: 0.96),
                borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
                border: Border.all(
                  color: AppColors.primary.withValues(alpha: 0.4),
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.8),
                    blurRadius: 36,
                    offset: const Offset(0, -8),
                  ),
                  BoxShadow(
                    color: AppColors.primary.withValues(alpha: 0.15),
                    blurRadius: 28,
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Handle
                  const SizedBox(height: 12),
                  Container(
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Header
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Row(
                          children: [
                            const PulsingBeacon(size: 6, color: AppColors.primary),
                            const SizedBox(width: 8),
                            Text(
                              (sheetTitle ?? hint).toUpperCase(),
                              style: AppTypography.labelSm(
                                color: AppColors.primary,
                              ).copyWith(fontSize: 10, letterSpacing: 1.2, fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            color: AppColors.primary.withValues(alpha: 0.12),
                          ),
                          child: Text(
                            '${items.length} OPTIONS',
                            style: AppTypography.labelSm(color: AppColors.primary).copyWith(fontSize: 9),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  Divider(color: Colors.white.withValues(alpha: 0.08)),

                  // Options list
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: items.length,
                      itemBuilder: (ctx, idx) {
                        final item = items[idx];
                        final isSelected = item.value == value;

                        return Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: () {
                              HapticFeedback.selectionClick();
                              Navigator.pop(ctx);
                              onChanged(item.value);
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? AppColors.primary.withValues(alpha: 0.12)
                                    : Colors.transparent,
                                border: Border(
                                  left: BorderSide(
                                    color: isSelected ? AppColors.primary : Colors.transparent,
                                    width: 3.5,
                                  ),
                                ),
                              ),
                              child: Row(
                                children: [
                                  if (item.icon != null) ...[
                                    Container(
                                      padding: const EdgeInsets.all(7),
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(8),
                                        color: isSelected
                                            ? AppColors.primary.withValues(alpha: 0.18)
                                            : AppColors.surfaceContainerLowest,
                                        border: Border.all(
                                          color: isSelected
                                              ? AppColors.primary.withValues(alpha: 0.4)
                                              : Colors.white.withValues(alpha: 0.06),
                                        ),
                                      ),
                                      child: Icon(
                                        item.icon,
                                        size: 16,
                                        color: isSelected
                                            ? AppColors.primary
                                            : (item.iconColor ?? AppColors.outline),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                  ],
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          item.label,
                                          style: AppTypography.bodyMd(
                                            color: isSelected ? AppColors.primary : AppColors.onSurface,
                                          ).copyWith(
                                            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                                            fontSize: 13.5,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                        if (item.subtitle != null) ...[
                                          const SizedBox(height: 2),
                                          Text(
                                            item.subtitle!,
                                            style: AppTypography.labelSm(
                                              color: AppColors.onSurfaceVariant,
                                            ).copyWith(fontSize: 10),
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                        ],
                                      ],
                                    ),
                                  ),
                                  if (isSelected)
                                    const Icon(
                                      Icons.check_circle,
                                      size: 18,
                                      color: AppColors.primary,
                                    ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    CyberDropdownItem<T>? selectedItem;
    try {
      selectedItem = items.firstWhere((i) => i.value == value);
    } catch (_) {}

    return GestureDetector(
      onTap: () => _openSelectionSheet(context),
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: AppColors.surfaceContainerLowest,
          border: Border.all(
            color: selectedItem != null
                ? AppColors.primary.withValues(alpha: 0.4)
                : Colors.white.withValues(alpha: 0.1),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.3),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            if (prefixIcon != null || selectedItem?.icon != null) ...[
              Icon(
                selectedItem?.icon ?? prefixIcon,
                size: 18,
                color: selectedItem != null ? AppColors.primary : AppColors.outline,
              ),
              const SizedBox(width: 10),
            ],
            Expanded(
              child: Text(
                selectedItem?.label ?? hint,
                style: selectedItem != null
                    ? AppTypography.bodyMd(color: AppColors.onSurface).copyWith(fontSize: 13.5)
                    : AppTypography.bodyMd(color: AppColors.outline).copyWith(fontSize: 13.5),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                color: AppColors.surfaceContainerLow,
              ),
              child: const Icon(
                Icons.unfold_more,
                size: 16,
                color: AppColors.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
