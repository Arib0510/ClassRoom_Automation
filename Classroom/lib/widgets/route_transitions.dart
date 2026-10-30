import 'dart:math' as math;
import 'package:flutter/material.dart';

class Cube3DPageRoute<T> extends PageRouteBuilder<T> {
  final Widget page;

  Cube3DPageRoute({required this.page})
      : super(
          pageBuilder: (context, animation, secondaryAnimation) => page,
          transitionDuration: const Duration(milliseconds: 320),
          reverseTransitionDuration: const Duration(milliseconds: 280),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            final curvedIn = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutCubic,
              reverseCurve: Curves.easeInCubic,
            );

            return AnimatedBuilder(
              animation: curvedIn,
              builder: (context, childWidget) {
                final progress = curvedIn.value;
                // Subtle 3D perspective rotation (only ~6 degrees)
                final angle = (1.0 - progress) * (math.pi / 28);
                final slideX = (1.0 - progress) * 40.0;
                final scale = 0.95 + (0.05 * progress);

                return Transform(
                  alignment: Alignment.centerRight,
                  transform: Matrix4.identity()
                    ..setEntry(3, 2, 0.0008)
                    ..translate(slideX, 0.0, 0.0)
                    ..rotateY(-angle)
                    ..scale(scale),
                  child: Opacity(
                    opacity: progress.clamp(0.0, 1.0),
                    child: childWidget,
                  ),
                );
              },
              child: child,
            );
          },
        );
}

class DepthFadePageRoute<T> extends PageRouteBuilder<T> {
  final Widget page;

  DepthFadePageRoute({required this.page})
      : super(
          pageBuilder: (context, animation, secondaryAnimation) => page,
          transitionDuration: const Duration(milliseconds: 280),
          reverseTransitionDuration: const Duration(milliseconds: 240),
          transitionsBuilder: (context, animation, secondaryAnimation, child) {
            final curved = CurvedAnimation(
              parent: animation,
              curve: Curves.easeOutQuad,
            );

            return FadeTransition(
              opacity: curved,
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.96, end: 1.0).animate(curved),
                child: child,
              ),
            );
          },
        );
}
