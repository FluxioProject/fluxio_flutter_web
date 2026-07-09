import 'dart:math';
import 'package:flutter/material.dart';

class SparkPoint {
  final double value;
  final DateTime time;

  SparkPoint(this.value, this.time);
}

class SparklinePainter extends CustomPainter {
  final List<SparkPoint> data;

  SparklinePainter(this.data);

  static const int windowSeconds = 300; // fixed window

  @override
  void paint(Canvas c, Size s) {
    if (data.length < 2) return;

    const leftPad = 40.0;
    const rightPad = 16.0;
    const bottomPad = 22.0;

    // =========================
    // Fixed time window
    // =========================
    final now = DateTime.now();
    final startTime = now.subtract(const Duration(seconds: windowSeconds));
    final endTime = now;

    final totalMillis = endTime.difference(startTime).inMilliseconds;

    double mapX(DateTime t) {
      final elapsed = t.difference(startTime).inMilliseconds;
      final clamped = elapsed.clamp(0, totalMillis);

      return leftPad + (clamped / totalMillis) * (s.width - leftPad - rightPad);
    }

    // =========================
    // Dynamic Y scale
    // =========================
    final visibleData = data.where((p) => p.time.isAfter(startTime)).toList();

    if (visibleData.length < 2) return;

    final minVal = visibleData.map((e) => e.value).reduce(min);
    final maxVal = visibleData.map((e) => e.value).reduce(max);

    double range = maxVal - minVal;
    if (range.abs() < 1e-6) {
      range = maxVal == 0 ? 1 : maxVal.abs();
    }

    final padding = range * 0.15;
    final minY = minVal - padding;
    final maxY = maxVal + padding;
    final effectiveRange = maxY - minY;

    double mapY(double v) {
      return (s.height - bottomPad) -
          ((v - minY) / effectiveRange) * (s.height - bottomPad);
    }

    // =========================
    // Paints
    // =========================
    final axisPaint = Paint()
      ..color = Colors.white24
      ..strokeWidth = 1;

    final linePaint = Paint()
      ..color = const Color(0xFF7CFFCB)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final textStyle = const TextStyle(fontSize: 10, color: Colors.white54);
    final tp = TextPainter(textDirection: TextDirection.ltr);

    // =========================
    // Axes
    // =========================
    c.drawLine(
      Offset(leftPad, 0),
      Offset(leftPad, s.height - bottomPad),
      axisPaint,
    );

    c.drawLine(
      Offset(leftPad, s.height - bottomPad),
      Offset(s.width - rightPad, s.height - bottomPad),
      axisPaint,
    );
    // =========================
    // Labels Y
    // =========================
    const yDivisions = 4;

    for (int i = 0; i <= yDivisions; i++) {
      final v = minY + (effectiveRange / yDivisions) * i;
      final y = mapY(v);

      c.drawLine(
        Offset(leftPad, y),
        Offset(s.width - rightPad, y),
        Paint()
          ..color = Colors.white10
          ..strokeWidth = 0.8,
      );

      tp.text = TextSpan(text: v.toStringAsFixed(1), style: textStyle);
      tp.layout();
      tp.paint(c, Offset(0, y - tp.height / 2));
    }

    // =========================
    // Graph line
    // =========================
    final path = Path();

    for (int i = 0; i < visibleData.length; i++) {
      final p = visibleData[i];
      final x = mapX(p.time);
      final y = mapY(p.value);

      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }

    c.drawPath(path, linePaint);

    // =========================
    // Labels X (fixos)
    // =========================
    void drawXLabel(DateTime t) {
      final x = mapX(t);

      final label =
          '${t.hour.toString().padLeft(2, '0')}:'
          '${t.minute.toString().padLeft(2, '0')}:'
          '${t.second.toString().padLeft(2, '0')}';

      tp.text = TextSpan(text: label, style: textStyle);
      tp.layout();
      tp.paint(c, Offset(x - tp.width / 2, s.height - bottomPad + 4));
    }

    drawXLabel(startTime);
    drawXLabel(startTime.add(const Duration(seconds: windowSeconds ~/ 2)));
    drawXLabel(endTime);
  }

  @override
  bool shouldRepaint(covariant SparklinePainter oldDelegate) {
    return true;
  }
}
