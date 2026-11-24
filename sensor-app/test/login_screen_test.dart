import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pattern_sensor_collector/capture.dart';
import 'package:pattern_sensor_collector/enrollment_repository.dart';
import 'package:pattern_sensor_collector/login_screen.dart';
import 'package:pattern_sensor_collector/storage.dart';

class _PatternRepository extends EnrollmentRepository {
  final List<int> registered;
  _PatternRepository(this.registered)
      : super(SessionStorage(Directory.systemTemp));

  @override
  Future<bool> matchesPattern(String userId, List<int> nodes) async =>
      nodes.join('-') == registered.join('-');
}

EnrollmentProfile _user() {
  final now = DateTime.utc(2026, 11, 18);
  return EnrollmentProfile(
    userId: 'user001',
    displayName: '사용자 A',
    createdAt: now,
    updatedAt: now,
    hasPattern: true,
    regripAcknowledged: true,
    patternVerifierRef: 'ref',
    records: const [],
  );
}

Future<void> _draw(WidgetTester tester, List<(double, double)> points) async {
  final board = find.byType(CustomPaint).last;
  final rect = tester.getRect(board);
  Offset at((double, double) p) =>
      Offset(rect.left + rect.width * p.$1, rect.top + rect.height * p.$2);
  final gesture = await tester.startGesture(at(points.first));
  for (final p in points.skip(1)) {
    await tester.pump(const Duration(milliseconds: 50));
    await gesture.moveTo(at(p));
  }
  await tester.pump(const Duration(milliseconds: 50));
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('matching pattern shows first-factor success only',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: LoginPatternScreen(
          repository: _PatternRepository([1, 2, 3]), user: _user()),
    ));
    await _draw(tester, [(0.25, 0.25), (0.5, 0.25), (0.75, 0.25)]);
    expect(find.text('패턴 인증 성공'), findsOneWidget);
    expect(find.textContaining('1차 패턴 확인만 거쳤습니다'), findsOneWidget);
    final second = tester.widget<OutlinedButton>(
        find.widgetWithText(OutlinedButton, '2차 행동 인증 · 유효 데이터 40개부터 적용'));
    expect(second.onPressed, isNull);
    expect(find.text('인증되었습니다'), findsNothing);
  });

  testWidgets('wrong pattern shows failure and allows retry', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: LoginPatternScreen(
          repository: _PatternRepository([1, 2, 3]), user: _user()),
    ));
    await _draw(tester, [(0.25, 0.25), (0.25, 0.5), (0.25, 0.75)]);
    expect(find.text('인증 실패'), findsOneWidget);
    await tester.tap(find.text('다시 시도'));
    await tester.pumpAndSettle();
    expect(find.text('등록한 패턴을 그려 주세요.'), findsOneWidget);
  });

  testWidgets('planned feature screens are marked as not implemented',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: PlannedFeaturesScreen()));
    expect(find.text('준비 중'), findsNWidgets(2));
    await tester.tap(find.text('잠금 대기 · 관리자 잠금'));
    await tester.pumpAndSettle();
    expect(find.text('준비 중 · 추후 구현'), findsOneWidget);
  });

  test('enrollment tracker fails a touch that leaves the board', () {
    final tracker = PatternTracker(rejectOutsideBoard: true)
      ..accept({'type': 'DOWN', 'time': 1.0, 'x': 0.25, 'y': 0.25})
      ..accept({'type': 'MOVE', 'time': 1.1, 'x': 1.2, 'y': 0.25})
      ..accept({'type': 'UP', 'time': 1.2, 'x': 1.2, 'y': 0.25});
    expect(tracker.error, 'left_board');
    final lenient = PatternTracker()
      ..accept({'type': 'DOWN', 'time': 1.0, 'x': 0.25, 'y': 0.25})
      ..accept({'type': 'MOVE', 'time': 1.1, 'x': 1.2, 'y': 0.25});
    expect(lenient.error, isNull);
  });
}
