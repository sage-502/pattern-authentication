import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pattern_sensor_collector/main.dart' as app;
import 'package:pattern_sensor_collector/model.dart';
import 'package:pattern_sensor_collector/storage.dart';
import 'package:path_provider/path_provider.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('드로우 MOVE가 모든 방문점을 기록한다', (tester) async {
    await tester.pumpWidget(const app.CollectorApp(legacyCollector: true));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), 'PDRAG');
    await tester.enterText(find.byType(TextField).at(1), 'phoneDRAG');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('다음 →'), 300,
        scrollable: find.byType(Scrollable).first);
    await tester.drag(find.byType(ListView).first, const Offset(0, -200));
    await tester.pumpAndSettle();
    await tester.tap(find.text('다음 →'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('입력 화면으로 →'), 300,
        scrollable: find.byType(Scrollable).first);
    await tester.drag(find.byType(ListView).first, const Offset(0, -200));
    await tester.pumpAndSettle();
    await tester.tap(find.text('입력 화면으로 →'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('입력 시작'));
    await tester.pump();
    expect(find.byKey(const Key('capture_stopwatch')), findsOneWidget);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 850));
    });
    await tester.pumpAndSettle();
    expect(find.textContaining('패턴 입력 가능'), findsOneWidget);
    final rect = tester.getRect(find.byType(AndroidView));
    Offset node(double x, double y) =>
        Offset(rect.left + rect.width * x, rect.top + rect.height * y);
    final gesture = await tester.startGesture(node(0.50, 0.75));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveTo(node(0.50, 0.50));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveTo(node(0.50, 0.25));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.up();
    await tester.pump();
    expect(find.text('실제 입력 패턴'), findsNothing);
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(seconds: 5));
    });
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('실제 입력 패턴'), findsOneWidget);
    expect(find.text('8 - 5 - 2'), findsNWidgets(2));
    final documents = await getApplicationDocumentsDirectory();
    final records = await SessionStorage(
      Directory('${documents.path}/pattern_sensor_collector'),
    ).loadTrials();
    final trial = records.last;
    expect(trial.captureMode, TrialRecord.fixedWindow5Mode);
    expect(
      trial.captureStartMonotonic! - trial.buttonT0Monotonic!,
      closeTo(0.0, 1e-6),
    );
    expect(
      trial.captureEndMonotonic! - trial.captureStartMonotonic!,
      closeTo(5.0, 1e-6),
    );
    // WidgetTester synthesizes MotionEvent timestamps near zero. A real OS
    // input event is required to check native touch/elapsed clock alignment.
    expect(
      trial.sensors.any(
        (s) =>
            s.time > trial.buttonT0Monotonic! + 4.0 &&
            s.time < trial.captureEndMonotonic!,
      ),
      true,
    );
    final joined = assess(trial).joined.rows;
    expect(joined, isNotEmpty);
    expect(
      joined.every(
        (r) =>
            r.time >= trial.captureStartMonotonic! &&
            r.time < trial.captureEndMonotonic!,
      ),
      true,
    );
  });
}
