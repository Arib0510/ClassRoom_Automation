import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_colors.dart';

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

class _TactileCardState extends State<TactileCard>
    with SingleTickerProviderStateMixin {
  double _tiltX = 0.0;
  double _tiltY = 0.0;
  bool _isPressed = false;

  void _onPointerDown(PointerDownEvent event) {
    if (widget.onTap == null) return;
    setState(() {
      _isPressed = true;
    });
  }

  void _onPointerUp(PointerUpEvent event) {
    setState(() {
      _isPressed = false;
      _tiltX = 0.0;
      _tiltY = 0.0;
    });
  }

  void _onPointerCancel(PointerCancelEvent event) {
    setState(() {
      _isPressed = false;
      _tiltX = 0.0;
      _tiltY = 0.0;
    });
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!widget.enableTilt) return;
    final size = context.size;
    if (size == null) return;

    final localPos = event.localPosition;
    final dx = (localPos.dx - size.width / 2) / (size.width / 2);
    final dy = (localPos.dy - size.height / 2) / (size.height / 2);

    setState(() {
      _tiltX = -dy.clamp(-1.0, 1.0) * 0.08;
      _tiltY = dx.clamp(-1.0, 1.0) * 0.08;
    });
  }

  @override
  Widget build(BuildContext context) {
    final matrix = Matrix4.identity()
      ..setEntry(3, 2, 0.0012)
      ..rotateX(_tiltX)
      ..rotateY(_tiltY);

    return Padding(
      padding: widget.margin,
      child: Listener(
        onPointerDown: _onPointerDown,
        onPointerUp: _onPointerUp,
        onPointerCancel: _onPointerCancel,
        onPointerMove: _onPointerMove,
        child: GestureDetector(
          onTap: () {
            HapticFeedback.lightImpact();
            widget.onTap?.call();
          },
          child: AnimatedScale(
            scale: _isPressed ? 0.97 : 1.0,
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOutCubic,
            child: Transform(
              transform: matrix,
              alignment: FractionalOffset.center,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: widget.padding,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(widget.borderRadius),
                  color: widget.isActive
                      ? const Color(0xDA131E36)
                      : const Color(0xCC171B28),
                  border: Border.all(
                    color: widget.isActive
                        ? AppColors.primary.withValues(alpha: 0.38)
                        : Colors.white.withValues(alpha: 0.07),
                    width: 1.2,
                  ),
                  boxShadow: widget.isActive
                      ? [
                          BoxShadow(
                            color: AppColors.primary.withValues(alpha: 0.16),
                            blurRadius: 24,
                            spreadRadius: -4,
                          ),
                        ]
                      : [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.3),
                            blurRadius: 10,
                            offset: const Offset(0, 4),
                          ),
                        ],
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

