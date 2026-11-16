import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_colors.dart';

/// The app's on/off switch. The thumb stretches toward its destination as it
/// travels, then settles — a small physical cue that the tap registered.
class CyberSwitch extends StatefulWidget {
  final bool value;
  final ValueChanged<bool> onChanged;
  final double width;
  final double height;

  const CyberSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.width = 46.0,
    this.height = 28.0,
  });

  @override
  State<CyberSwitch> createState() => _CyberSwitchState();
}

class _CyberSwitchState extends State<CyberSwitch>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _position;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 260),
      value: widget.value ? 1.0 : 0.0,
    );
    _position = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
  }

  @override
  void didUpdateWidget(covariant CyberSwitch oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      if (widget.value) {
        _controller.forward();
      } else {
        _controller.reverse();
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
    const inset = 3.0;
    final thumb = widget.height - inset * 2;
    final travel = widget.width - inset * 2 - thumb;

    return Semantics(
      toggled: widget.value,
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          HapticFeedback.selectionClick();
          widget.onChanged(!widget.value);
        },
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            final t = _position.value;
            // Peaks mid-flight, zero at rest.
            final stretch = (1 - (2 * _controller.value - 1).abs()) * 6.0;
            // While travelling right the thumb trails behind its leading
            // edge; travelling left it leads with the left edge.
            final goingRight =
                _controller.status == AnimationStatus.forward;

            return Container(
              width: widget.width,
              height: widget.height,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(widget.height / 2),
                color: Color.lerp(
                  AppColors.surfaceContainerHigh,
                  AppColors.primary,
                  t,
                ),
                border: Border.all(
                  color: Color.lerp(
                    AppColors.outlineVariant,
                    AppColors.primary,
                    t,
                  )!,
                ),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.primary.withValues(alpha: 0.30 * t),
                    blurRadius: 10,
                    spreadRadius: -2,
                  ),
                ],
              ),
              child: Stack(
                children: [
                  Positioned(
                    // The border takes 1px, so offset by inset - 1.
                    left: (inset - 1) +
                        travel * t -
                        (goingRight ? stretch : 0),
                    top: inset - 1,
                    child: Container(
                      width: thumb + stretch,
                      height: thumb,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(thumb / 2),
                        color: Color.lerp(
                          AppColors.outline,
                          AppColors.onPrimary,
                          t,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: AppColors.shadow(0.35),
                            blurRadius: 4,
                            offset: const Offset(0, 1),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
