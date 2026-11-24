import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pattern_sensor_collector/data_management.dart';
import 'package:pattern_sensor_collector/model.dart';
import 'package:pattern_sensor_collector/pattern_group_screen.dart';
import 'package:pattern_sensor_collector/storage.dart';

TrialSummary summary(String id, TrialStatus status, String mode) =>
    TrialSummary(
      id: id,
      targetPattern: '1-2-5-8',
      actualPattern: '1-2-5-8',
      participantId: 'P1',
      sessionId: 'S1',
      displayName: '패턴 A',
      reason: status == TrialStatus.success ? '' : 'TEST_REASON',
      source: 'json_v1.1',
      captureMode: mode,
      createdAt: DateTime.now().toUtc(),
      status: status,
      accelCount: 400,
      gyroCount: 400,
      mlRowCount: 800,
    );

void main() {
  test('long list ID is shortened while the full ID remains available', () {
    const id = 'T173860993996344_d1b0c8';
    expect(shortTrialId(id), isNot(id));
    expect(shortTrialId(id), startsWith('T173860993'));
    expect(shortTrialId(id), endsWith('d1b0c8'));
  });

  testWidgets('small screen keeps primary upload and all exports reachable',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final root = Directory.systemTemp.createTempSync('group_ui_test_');
    addTearDown(() => root.deleteSync(recursive: true));
    const id = 'T173860993996344_d1b0c8';
    final fixed = summary(id, TrialStatus.success, TrialRecord.fixedWindow5Mode);
    final legacy =
        summary('Tlegacy', TrialStatus.success, TrialRecord.legacyMode);
    final failed =
        summary('Tfailed', TrialStatus.failed, TrialRecord.fixedWindowMode);
    final selected = <String>{id, legacy.id, failed.id};
    Set<String>? uploaded;
    bool? uploadedDiagnostics;
    await tester.pumpWidget(MaterialApp(
        home: MediaQuery(
      data: MediaQueryData.fromView(tester.view).copyWith(
        padding: const EdgeInsets.only(bottom: 24),
        textScaler: TextScaler.linear(1.4),
      ),
      child: PatternGroupScreen(
        pattern: '1-2-5-8',
        storage: SessionStorage(root),
        all: [fixed, legacy, failed],
        selected: selected,
        onSelectionChanged: () {},
        onExport: (_, __, ___) async {},
        onUpload: (ids, diagnostics) async {
          uploaded = ids;
          uploadedDiagnostics = diagnostics;
        },
      ),
    )));
    expect(tester.takeException(), isNull);
    expect(find.text(id), findsNothing);
    expect(find.textContaining(shortTrialId(id)), findsOneWidget);
    await tester.tap(find.byKey(const Key('pattern_group_trial_$id')));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();
    expect(find.text(id), findsOneWidget);
    await tester.tap(find.text('닫기'));
    await tester.pumpAndSettle();

    await tester.scrollUntilVisible(
        find.byKey(const Key('pattern_group_primary_upload')), 240,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('pattern_group_primary_upload')));
    expect(uploaded, {id});
    expect(uploadedDiagnostics, false);
    await tester.scrollUntilVisible(
        find.byKey(const Key('pattern_group_more_exports')), 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('기타 내보내기'));
    await tester.pumpAndSettle();
    expect(find.textContaining('선택 구버전 별도 내보내기'), findsOneWidget);
    expect(find.textContaining('선택 실패/검토 내보내기'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('선택 실패/검토 Drive로 업로드'), 160,
        scrollable: find.byType(Scrollable).first);
    expect(tester.takeException(), isNull);
  });
}
