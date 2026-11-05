import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

class PulsingBeacon extends StatefulWidget {
  final double size;
  final Color color;
  final bool isPulsing;

  const PulsingBeacon({
    super.key,
    this.size = 6.0,
    this.color = AppColors.primary,
    this.isPulsing = true,
  });

  @override
  State<PulsingBeacon> createState() => _PulsingBeaconState();
}

class _PulsingBeaconState extends State<PulsingBeacon>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );
    if (widget.isPulsing) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(covariant PulsingBeacon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPulsing && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!widget.isPulsing && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final scale = widget.isPulsing ? 0.85 + (_controller.value * 0.35) : 1.0;
        final alpha = widget.isPulsing ? 0.4 + (_controller.value * 0.6) : 0.8;

        return Stack(
          alignment: Alignment.center,
          children: [
            // Outer glow halo
            if (widget.isPulsing)
              Transform.scale(
                scale: scale * 1.8,
                child: Container(
                  width: widget.size,
                  height: widget.size,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.color.withValues(alpha: 0.25 * alpha),
                  ),
                ),
              ),
            // Solid center beacon
            Transform.scale(
              scale: scale,
              child: Container(
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.color.withValues(alpha: alpha),
                  boxShadow: [
                    BoxShadow(
                      color: widget.color.withValues(alpha: 0.6 * alpha),
                      blurRadius: widget.size * 1.2,
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

