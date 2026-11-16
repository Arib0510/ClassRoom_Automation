import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_colors.dart';
import '../theme/app_typography.dart';

enum ToastType { success, error, info }

/// A brief, non-blocking message that drops in from the top of the screen.
/// A thin bar along the bottom edge drains to show how long it will stay;
/// swipe up or tap the close icon to dismiss it early.
class CyberToast {
  static OverlayEntry? _current;

  static void show(
    BuildContext context, {
    required String message,
    ToastType type = ToastType.info,
    Duration duration = const Duration(milliseconds: 2800),
  }) {
    final overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;

    HapticFeedback.lightImpact();

    // One toast at a time: a newer message replaces the one on screen
    // instead of stacking on top of it.
    _removeCurrent();

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) => _CyberToastWidget(
        message: message,
        type: type,
        duration: duration,
        onDismiss: () {
          if (_current == entry) _current = null;
          if (entry.mounted) entry.remove();
        },
      ),
    );

    _current = entry;
    overlay.insert(entry);
  }

  static void _removeCurrent() {
    final entry = _current;
    _current = null;
    if (entry != null && entry.mounted) entry.remove();
  }
}

class _CyberToastWidget extends StatefulWidget {
  final String message;
  final ToastType type;
  final VoidCallback onDismiss;
  final Duration duration;

  const _CyberToastWidget({
    required this.message,
    required this.type,
    required this.onDismiss,
    required this.duration,
  });

  @override
  State<_CyberToastWidget> createState() => _CyberToastWidgetState();
}

class _CyberToastWidgetState extends State<_CyberToastWidget>
    with TickerProviderStateMixin {
  late final AnimationController _entrance;
  late final AnimationController _life;
  bool _closing = false;

  @override
  void initState() {
    super.initState();
    _entrance = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
      reverseDuration: const Duration(milliseconds: 220),
    )..forward();

    _life = AnimationController(vsync: this, duration: widget.duration)
      ..addStatusListener((status) {
        if (status == AnimationStatus.completed) _close();
      })
      ..forward();
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    _life.stop();
    try {
      await _entrance.reverse();
    } on TickerCanceled {
      // Disposed mid-animation; nothing left to do.
      return;
    }
    if (mounted) widget.onDismiss();
  }

  @override
  void dispose() {
    _entrance.dispose();
    _life.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Color accent;
    final IconData icon;

    switch (widget.type) {
      case ToastType.success:
        accent = AppColors.onlineMint;
        icon = Icons.check_circle_rounded;
        break;
      case ToastType.error:
        accent = AppColors.error;
        icon = Icons.error_rounded;
        break;
      case ToastType.info:
        accent = AppColors.primary;
        icon = Icons.info_rounded;
        break;
    }

    final topPadding = MediaQuery.of(context).padding.top;
    final slide = CurvedAnimation(
      parent: _entrance,
      curve: Curves.easeOutBack,
      reverseCurve: Curves.easeIn,
    );

    return Positioned(
      top: topPadding + 10,
      left: 16,
      right: 16,
      child: AnimatedBuilder(
        animation: _entrance,
        builder: (context, child) {
          return Opacity(
            opacity: _entrance.value.clamp(0.0, 1.0),
            child: Transform.translate(
              offset: Offset(0, -28 * (1 - slide.value)),
              child: Transform.scale(
                scale: 0.96 + 0.04 * slide.value,
                child: child,
              ),
            ),
          );
        },
        child: Dismissible(
          key: const ValueKey('cyber_toast'),
          direction: DismissDirection.up,
          onDismissed: (_) => widget.onDismiss(),
          child: Material(
            color: Colors.transparent,
            child: Semantics(
              liveRegion: true,
              child: Container(
                clipBehavior: Clip.antiAlias,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  color: AppColors.sheet,
                  border: Border.all(color: accent.withValues(alpha: 0.35)),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.shadow(0.55),
                      blurRadius: 28,
                      spreadRadius: -6,
                      offset: const Offset(0, 12),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 11, 6, 9),
                      child: Row(
                        children: [
                          Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: accent.withValues(alpha: 0.14),
                            ),
                            child: Icon(icon, size: 18, color: accent),
                          ),
                          const SizedBox(width: 11),
                          Expanded(
                            child: Text(
                              widget.message,
                              style: AppTypography.bodySm(
                                color: AppColors.onSurface,
                              ).copyWith(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          IconButton(
                            onPressed: _close,
                            tooltip: 'Dismiss',
                            visualDensity: VisualDensity.compact,
                            icon: Icon(
                              Icons.close_rounded,
                              size: 17,
                              color: AppColors.outline,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Time-remaining bar.
                    AnimatedBuilder(
                      animation: _life,
                      builder: (context, _) {
                        return Align(
                          alignment: Alignment.centerLeft,
                          child: FractionallySizedBox(
                            widthFactor: (1 - _life.value).clamp(0.0, 1.0),
                            child: Container(
                              height: 2.5,
                              color: accent.withValues(alpha: 0.75),
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
