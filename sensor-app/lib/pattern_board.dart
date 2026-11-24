import 'package:flutter/material.dart';

import 'capture.dart';

/// The existing 3×3 board used by both research capture and enrollment.
class BoardPainter extends CustomPainter {
  final List<int> target, actual;
  BoardPainter({required this.target, required this.actual});

  @override
  void paint(Canvas canvas, Size size) {
    Offset center(int n) {
      final p = nodePoint(n);
      return Offset(p.$1 * size.width, p.$2 * size.height);
    }

    final guide = Paint()
      ..color = const Color(0xffb9a7f8)
      ..strokeWidth = 5
      ..style = PaintingStyle.stroke;
    for (var i = 0; i < target.length - 1; i++) {
      canvas.drawLine(center(target[i]), center(target[i + 1]), guide);
    }
    final stroke = Paint()
      ..color = const Color(0xff4261ee)
      ..strokeWidth = 6
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < actual.length - 1; i++) {
      canvas.drawLine(center(actual[i]), center(actual[i + 1]), stroke);
    }
    for (var n = 1; n <= 9; n++) {
      final active = target.contains(n), visited = actual.contains(n);
      canvas.drawCircle(
        center(n),
        size.width * 0.065,
        Paint()
          ..color = visited
              ? const Color(0xff6847e8)
              : active
                  ? const Color(0xff9d79f4)
                  : const Color(0xffe3e3eb),
      );
      final label = TextPainter(
        text: TextSpan(
          text: '$n',
          style: TextStyle(
            fontSize: size.width * 0.052,
            fontWeight: FontWeight.bold,
            color: active ? Colors.white : const Color(0xff77758b),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(
        canvas,
        center(n) - Offset(label.width / 2, label.height / 2),
      );
    }
  }

  @override
  bool shouldRepaint(covariant BoardPainter old) =>
      old.target.join() != target.join() || old.actual.join() != actual.join();
}
