import 'dart:math' as math;

import 'package:deskconn_mobile_app/theme/colors.dart';
import 'package:flutter/material.dart';

class RingGauge extends StatelessWidget {
  final double percent;
  final String value;
  final String label;
  final Color color;
  final double size;
  final double strokeWidth;

  const RingGauge({
    super.key,
    required this.percent,
    required this.value,
    required this.label,
    required this.color,
    this.size = 176,
    this.strokeWidth = 14,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          CustomPaint(
            size: Size(size, size),
            painter: _RingGaugePainter(
              percent: percent.clamp(0, 100).toDouble(),
              color: color,
              strokeWidth: strokeWidth,
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                value,
                style: TextStyle(fontSize: math.max(size * 0.155, 12), fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(fontSize: math.max(size * 0.075, 9), color: DeskconnPalette.of(context).subtle),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RingGaugePainter extends CustomPainter {
  final double percent;
  final Color color;
  final double strokeWidth;

  _RingGaugePainter({required this.percent, required this.color, required this.strokeWidth});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.shortestSide - strokeWidth) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    final trackPaint = Paint()
      ..color = color.withValues(alpha: 0.15)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, radius, trackPaint);

    final progressPaint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    const startAngle = -math.pi / 2;
    final sweepAngle = 2 * math.pi * (percent / 100);
    canvas.drawArc(rect, startAngle, sweepAngle, false, progressPaint);
  }

  @override
  bool shouldRepaint(covariant _RingGaugePainter oldDelegate) {
    return oldDelegate.percent != percent || oldDelegate.color != color || oldDelegate.strokeWidth != strokeWidth;
  }
}
