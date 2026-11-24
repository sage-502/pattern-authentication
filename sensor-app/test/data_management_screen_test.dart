import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pattern_sensor_collector/data_management.dart';
import 'package:pattern_sensor_collector/data_management_screen.dart';
import 'package:pattern_sensor_collector/export_workflow.dart';
import 'package:pattern_sensor_collector/model.dart';
import 'package:pattern_sensor_collector/pattern_group_screen.dart';
import 'package:pattern_sensor_collector/storage.dart';

class _SummaryStorage extends SessionStorage {
  final List<TrialSummary> summaries;
  _SummaryStorage(super.root, this.summaries);

  @override
  Future<List<TrialSummary>> loadSummaries() async => summaries;
}

TrialSummary _summary(String id, TrialStatus status, String mode,
        {String participantId = 'P1', String pattern = '1-2-5-8'}) =>
    TrialSummary(
      id: id,
      targetPattern: pattern,
      actualPattern: pattern,
      participantId: participantId,
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
  test('Drive batches never combine different participants or patterns', () {
    final batches = planDriveUploadBatches([
      _summary('T1', TrialStatus.success, TrialRecord.fixedWindow5Mode),
      _summary('T2', TrialStatus.success, TrialRecord.fixedWindow5Mode),
      _summary('T3', TrialStatus.success, TrialRecord.fixedWindow5Mode,
          participantId: 'P2'),
      _summary('T4', TrialStatus.success, TrialRecord.fixedWindow5Mode,
          pattern: '2-3-6-9'),
    ]);
    expect(batches.length, 3);
    expect(
        batches.map((batch) => batch.map((s) => s.id).toSet()),
        containsAll([
          {'T1', 'T2'},
          {'T3'},
          {'T4'}
        ]));
    for (final batch in batches) {
      expect(batch.map((s) => s.participantId).toSet(), hasLength(1));
      expect(batch.map((s) => s.targetPattern).toSet(), hasLength(1));
    }
  });

  testWidgets('management actions remain reachable above system navigation',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    final root = Directory.systemTemp.createTempSync('management_ui_test_');
    addTearDown(() => root.deleteSync(recursive: true));
    final records = [
      _summary('Tfixed', TrialStatus.success, TrialRecord.fixedWindow5Mode),
      _summary('Tlegacy', TrialStatus.success, TrialRecord.legacyMode),
      _summary('Tfailed', TrialStatus.failed, TrialRecord.fixedWindow5Mode),
    ];
    final storage = _SummaryStorage(root, records);
    final workflow = ExportWorkflow.production(storage);
    addTearDown(workflow.dispose);
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: MediaQueryData.fromView(tester.view).copyWith(
          padding: const EdgeInsets.only(bottom: 24),
          textScaler: TextScaler.linear(1.4),
        ),
        child: DataManagementScreen(storage: storage, workflow: workflow),
      ),
    ));
    await tester.runAsync(() => Future<void>.delayed(
          const Duration(milliseconds: 50),
        ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final upload = find.byKey(const Key('data_management_primary_upload'));
    expect(tester.widget<FilledButton>(upload).onPressed, isNull);
    await tester.tap(find.text('보이는 패턴 선택'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(upload).onPressed, isNotNull);
    expect(find.text('선택 1건 업로드'), findsOneWidget);
    expect(find.textContaining('구버전 1건 · 실패/검토 1건'), findsOneWidget);

    final scrollable = find
        .descendant(
          of: find.byKey(const Key('data_management_scroll')),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.byKey(const Key('data_management_group_1-2-5-8')),
      120,
      scrollable: scrollable,
    );
    await tester.tap(find.text('패턴 1-2-5-8'));
    await tester.pumpAndSettle();
    expect(find.byType(PatternGroupScreen), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('data_management_primary_upload')),
      -120,
      scrollable: scrollable,
    );
    expect(tester.widget<FilledButton>(upload).onPressed, isNotNull);
    expect(find.text('선택 1건 업로드'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.byKey(const Key('data_management_more_exports')),
      180,
      scrollable: scrollable,
    );
    await tester.tap(find.text('기타 내보내기'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.textContaining('전체 성공 Drive 업로드'),
      180,
      scrollable: scrollable,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final lastAction = find.textContaining('전체 성공 Drive 업로드');
    final safeBottom = tester.view.physicalSize.height - 24;
    final actionBottom = tester.getBottomLeft(lastAction).dy;
    expect(actionBottom, lessThan(safeBottom));
  });
}
