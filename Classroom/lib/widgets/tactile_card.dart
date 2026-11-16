import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_colors.dart';

/// A pressable surface card. It leans a few degrees toward the finger while
/// held and springs back on release. When [isActive] it picks up the accent
/// border and a soft glow.
class TactileCard extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final bool isActive;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;
  final double borderRadius;
  final bool enableTilt;

  const TactileCard({
    super.key,
    required this.child,
    this.onTap,
    this.isActive = false,
    this.padding = const EdgeInsets.all(16.0),
    this.margin = EdgeInsets.zero,
    this.borderRadius = 16.0,
    this.enableTilt = true,
  });

  @override
  State<TactileCard> createState() => _TactileCardState();
}

class _TactileCardState extends State<TactileCard> {
  double _tiltX = 0.0;
  double _tiltY = 0.0;
  bool _isPressed = false;

  void _onPointerDown(PointerDownEvent event) {
    if (widget.onTap == null) return;
    setState(() => _isPressed = true);
    _updateTilt(event.localPosition);
  }

  void _release() {
    if (!_isPressed && _tiltX == 0 && _tiltY == 0) return;
    setState(() {
      _isPressed = false;
      _tiltX = 0.0;
      _tiltY = 0.0;
    });
  }

  void _updateTilt(Offset localPos) {
    if (!widget.enableTilt || !_isPressed) return;
    final size = context.size;
    if (size == null || size.isEmpty) return;

    final dx = (localPos.dx - size.width / 2) / (size.width / 2);
    final dy = (localPos.dy - size.height / 2) / (size.height / 2);

    setState(() {
      _tiltX = -dy.clamp(-1.0, 1.0) * 0.045;
      _tiltY = dx.clamp(-1.0, 1.0) * 0.045;
    });
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.isActive;

    return Padding(
      padding: widget.margin,
      child: Listener(
        onPointerDown: _onPointerDown,
        onPointerUp: (_) => _release(),
        onPointerCancel: (_) => _release(),
        onPointerMove: (e) => _updateTilt(e.localPosition),
        child: GestureDetector(
          onTap: widget.onTap == null
              ? null
              : () {
                  HapticFeedback.lightImpact();
                  widget.onTap!.call();
                },
          child: TweenAnimationBuilder<Offset>(
            tween: Tween<Offset>(end: Offset(_tiltX, _tiltY)),
            duration: Duration(milliseconds: _isPressed ? 90 : 420),
            curve: _isPressed ? Curves.easeOut : Curves.elasticOut,
            builder: (context, tilt, child) {
              return Transform(
                transform: Matrix4.identity()
                  ..setEntry(3, 2, 0.0012)
                  ..rotateX(tilt.dx)
                  ..rotateY(tilt.dy),
                alignment: FractionalOffset.center,
                child: child,
              );
            },
            child: AnimatedScale(
              scale: _isPressed ? 0.975 : 1.0,
              duration: const Duration(milliseconds: 160),
              curve: Curves.easeOutCubic,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                padding: widget.padding,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(widget.borderRadius),
                  color: active
                      ? Color.alphaBlend(
                          AppColors.primary.withValues(
                            alpha: AppColors.isDark ? 0.10 : 0.08,
                          ),
                          AppColors.surfaceContainerLow,
                        )
                      : AppColors.surfaceContainerLow,
                  border: Border.all(
                    color: active
                        ? AppColors.primary.withValues(
                            alpha: AppColors.isDark ? 0.50 : 0.68,
                          )
                        : AppColors.overlay(AppColors.isDark ? 0.08 : 0.10),
                    width: active ? 1.5 : 1.0,
                  ),
                  boxShadow: active
                      ? [
                          BoxShadow(
                            color: AppColors.primary.withValues(
                              alpha: AppColors.isDark ? 0.18 : 0.15,
                            ),
                            blurRadius: 18,
                            spreadRadius: -4,
                            offset: const Offset(0, 5),
                          ),
                        ]
                      : AppColors.cardShadow(),
                ),
                child: widget.child,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
