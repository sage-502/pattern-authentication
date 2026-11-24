import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:pattern_sensor_collector/data_management.dart';
import 'package:pattern_sensor_collector/model.dart';
import 'package:pattern_sensor_collector/pattern_group_screen.dart';
import 'package:pattern_sensor_collector/storage.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('패턴 상세 하단 메뉴가 시스템 내비게이션 위에서 스크롤된다', (tester) async {
    final root = await Directory.systemTemp.createTemp('layout_test_');
    addTearDown(() => root.delete(recursive: true));
    final now = DateTime.now().toUtc();
    TrialSummary record(String id, TrialStatus status) => TrialSummary(
          id: id,
          targetPattern: '1-2-5-8',
          actualPattern: '1-2-5-8',
          participantId: 'P1',
          sessionId: 'S1',
          displayName: '패턴 A',
          reason: status == TrialStatus.success ? '' : 'TEST',
          source: 'json_v1.1',
          captureMode: TrialRecord.fixedWindow5Mode,
          createdAt: now,
          status: status,
          accelCount: 400,
          gyroCount: 400,
          mlRowCount: 800,
        );
    await tester.pumpWidget(MaterialApp(
      home: PatternGroupScreen(
        pattern: '1-2-5-8',
        storage: SessionStorage(root),
        all: [
          record('T173860993996344_d1b0c8', TrialStatus.success),
          record('T173860993996345_d1b0c9', TrialStatus.failed),
        ],
        selected: {'T173860993996344_d1b0c8', 'T173860993996345_d1b0c9'},
        onSelectionChanged: () {},
        onExport: (_, __, ___) async {},
        onUpload: (_, __) async {},
      ),
    ));
    await tester.pumpAndSettle();
    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.byKey(const Key('pattern_group_more_exports')),
      250,
      scrollable: scrollable,
    );
    await tester.tap(find.text('기타 내보내기'));
    await tester.pumpAndSettle();
    final lastAction = find.text('선택 실패/검토 Drive로 업로드');
    await tester.scrollUntilVisible(lastAction, 180, scrollable: scrollable);
    await tester.pumpAndSettle();
    final screen =
        MediaQuery.sizeOf(tester.element(find.byType(PatternGroupScreen)));
    final navInset = MediaQuery.viewPaddingOf(
      tester.element(find.byType(PatternGroupScreen)),
    ).bottom;
    expect(tester.getRect(lastAction).bottom,
        lessThanOrEqualTo(screen.height - navInset + 1));
    expect(tester.takeException(), isNull);
  });
}
