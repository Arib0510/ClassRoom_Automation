import 'package:flutter/material.dart';
import '../theme/app_colors.dart';

/// A small status dot. When [isPulsing] it emits a soft sonar ring that
/// expands and fades, which reads as "live" without the dot itself
/// flickering. The ring paints outside the dot's layout box, so the widget
/// always occupies exactly [size] × [size].
class PulsingBeacon extends StatefulWidget {
  final double size;
  final Color? color;
  final bool isPulsing;

  const PulsingBeacon({
    super.key,
    this.size = 6.0,
    this.color,
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
      duration: const Duration(milliseconds: 1800),
    );
    if (widget.isPulsing) {
      _controller.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant PulsingBeacon oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPulsing && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.isPulsing && _controller.isAnimating) {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? AppColors.primary;
    final size = widget.size;

    return SizedBox(
      width: size,
      height: size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          final t = Curves.easeOut.transform(_controller.value);
          return Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              if (widget.isPulsing)
                Transform.scale(
                  scale: 1.0 + t * 1.6,
                  child: Container(
                    width: size,
                    height: size,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: color.withValues(alpha: 0.40 * (1.0 - t)),
                    ),
                  ),
                ),
              child!,
            ],
          );
        },
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.isPulsing ? color : color.withValues(alpha: 0.7),
          ),
        ),
      ),
    );
  }
}
