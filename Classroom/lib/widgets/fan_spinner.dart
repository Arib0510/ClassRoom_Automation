import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import 'ceiling_fan_icon.dart';

class FanSpinner extends StatefulWidget {
  final bool isSpinning;
  final int speed; // 0..4
  final bool reverse;
  final double size;
  final Color color;

  const FanSpinner({
    super.key,
    required this.isSpinning,
    this.speed = 3,
    this.reverse = false,
    this.size = 20.0,
    this.color = AppColors.primary,
  });

  @override
  State<FanSpinner> createState() => _FanSpinnerState();
}

class _FanSpinnerState extends State<FanSpinner>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: _getDuration(widget.speed),
    );
    if (widget.isSpinning && widget.speed > 0) {
      _controller.repeat();
    }
  }

  Duration _getDuration(int speed) {
    switch (speed) {
      case 1:
        return const Duration(milliseconds: 3000);
      case 2:
        return const Duration(milliseconds: 2000);
      case 3:
        return const Duration(milliseconds: 1200);
      case 4:
        return const Duration(milliseconds: 700);
      default:
        return const Duration(milliseconds: 1500);
    }
  }

  @override
  void didUpdateWidget(covariant FanSpinner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.speed != widget.speed) {
      _controller.duration = _getDuration(widget.speed);
    }

    if (widget.isSpinning && widget.speed > 0) {
      if (!_controller.isAnimating) {
        _controller.repeat();
      }
    } else {
      if (_controller.isAnimating) {
        _controller.stop();
      }
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
        final angle = (widget.reverse ? -1 : 1) *
            _controller.value *
            2 *
            math.pi;
        return CeilingFanIcon(
          size: widget.size,
          color: widget.isSpinning ? widget.color : AppColors.outline,
          angle: angle,
        );
      },
    );
  }
}
