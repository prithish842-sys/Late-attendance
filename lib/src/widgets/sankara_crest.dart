import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The Sankara College crest, drawn as a simple navy shield with the
/// college's maroon/cream banding. Used small and top-left — never centered
/// or hero-sized (DESIGN.md §3.1).
class SankaraCrest extends StatelessWidget {
  const SankaraCrest({super.key, this.size = 40});

  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _CrestPainter(),
      ),
    );
  }
}

class _CrestPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    final shield = Path()
      ..moveTo(w * 0.5, 0)
      ..lineTo(w * 0.86, h * 0.05)
      ..cubicTo(w * 0.96, h * 0.12, w, h * 0.35, w * 0.78, h * 0.62)
      ..cubicTo(w * 0.68, h * 0.76, w * 0.58, h * 0.92, w * 0.5, h)
      ..cubicTo(w * 0.42, h * 0.92, w * 0.32, h * 0.76, w * 0.22, h * 0.62)
      ..cubicTo(w * 0, h * 0.35, w * 0.04, h * 0.12, w * 0.14, h * 0.05)
      ..close();

    final fill = Paint()
      ..style = PaintingStyle.fill
      ..color = AppColors.navy900;
    canvas.drawPath(shield, fill);

    final outline = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w * 0.02
      ..color = AppColors.maroon700;
    canvas.drawPath(shield, outline);

    // Inner maroon band and cream accent — evokes the ID-card banding.
    final band = Paint()..color = AppColors.maroon700;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * 0.26, h * 0.30, w * 0.48, h * 0.16),
        Radius.circular(w * 0.01),
      ),
      band,
    );

    final accent = Paint()..color = AppColors.cream50;
    final star = Path();
    final cx = w * 0.5;
    final cy = h * 0.42;
    final outer = w * 0.16;
    final inner = w * 0.065;
    for (var i = 0; i < 10; i++) {
      final radius = i.isEven ? outer : inner;
      final angle = -math.pi / 2 + i * math.pi / 5;
      final x = cx + radius * math.cos(angle);
      final y = cy + radius * math.sin(angle);
      if (i == 0) {
        star.moveTo(x, y);
      } else {
        star.lineTo(x, y);
      }
    }
    star.close();
    canvas.drawPath(star, accent);
  }

  @override
  bool shouldRepaint(covariant _CrestPainter oldDelegate) => false;
}