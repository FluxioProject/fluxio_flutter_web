import 'package:flutter/material.dart';

class GradientBackground extends StatelessWidget {
  final Widget child;
  final bool image;
  const GradientBackground({
    super.key,
    required this.child,
    required this.image,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        image
            ? Opacity(
                opacity: 0.09,
                child: Image.asset('assets/images/bg.png', fit: BoxFit.cover),
              )
            : Opacity(
                opacity: 0.03,
                child: Image.asset('assets/images/bg.png', fit: BoxFit.cover),
              ),
        Positioned.fill(
          child: IgnorePointer(
            child: Opacity(
              opacity: 0.55,
              child: Container(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0.0, -0.2),
                    radius: 1.05,
                    colors: [
                      const Color(0xFF00FF99).withOpacity(0.14),
                      Colors.transparent,
                    ],
                    stops: const [0.0, 1.0],
                  ),
                ),
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: Opacity(
              opacity: 0.9,
              child: Container(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0.9, 0.9),
                    radius: 1.2,
                    colors: [
                      const Color(0xFF101A16).withOpacity(0.55),
                      Colors.transparent,
                    ],
                    stops: const [0.0, 1.0],
                  ),
                ),
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: IgnorePointer(
            child: Container(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment.center,
                  radius: 1.1,
                  colors: [Colors.transparent, Colors.black.withOpacity(0.55)],
                  stops: const [0.55, 1.0],
                ),
              ),
            ),
          ),
        ),
        Positioned.fill(child: child),
      ],
    );
  }
}
