import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pattern_sensor_collector/enrollment_screen.dart';

void main() {
  testWidgets('pattern creation retains the first node and crossing order',
      (tester) async {
    List<int>? entered;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: PatternInputBoard(onPattern: (nodes) => entered = nodes),
      ),
    ));
    final board = find.descendant(
      of: find.byType(PatternInputBoard),
      matching: find.byType(CustomPaint),
    );
    final rect = tester.getRect(board.first);
    Offset node(double x, double y) =>
        Offset(rect.left + rect.width * x, rect.top + rect.height * y);

    final gesture = await tester.startGesture(node(0.25, 0.25));
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.moveTo(node(0.5, 0.25));
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.moveTo(node(0.75, 0.25));
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.up();
    await tester.pump();

    expect(entered, [1, 2, 3]);
  });
}
