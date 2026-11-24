import 'dart:io';
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pattern_sensor_collector/data_management.dart';
import 'package:pattern_sensor_collector/model.dart';
import 'package:pattern_sensor_collector/storage.dart';

TrialRecord fixture({
  String id = 'T001',
  String participantId = 'P1',
  List<int> target = const [1, 2, 5, 8],
  List<int>? visitNodes,
  bool withSensors = true,
  bool legacy = false,
  bool fiveSeconds = true,
  double? down = 100.6,
  double? up = 101.1,
  bool windowComplete = true,
  String? windowError,
  double dispatchDelayMs = 5,
  double hitRadiusNorm = 0.12,
}) {
  final sensors = <SensorSample>[];
  for (var i = 0; withSensors && i <= (fiveSeconds ? 500 : 450); i++) {
    final t = 100.0 + i * 0.01;
    sensors.add(SensorSample(t, 1, 2, 9.8, 'ACCEL'));
    sensors.add(SensorSample(t + 0.005, 0.1, 0.2, 0.3, 'GYRO'));
  }
  return TrialRecord(
    id: id,
    sessionId: 'S1',
    index: 1,
    participantId: participantId,
    deviceId: 'phone1',
    hand: 'right',
    posture: 'seated',
    holdingHand: 'left',
    target: target,
    visits: down == null
        ? []
        : (visitNodes ?? const [1, 2, 5, 8])
            .asMap()
            .entries
            .map((e) => NodeVisit(
                e.value, down + e.key * 0.1, 'touch_detected', e.key != 0))
            .toList(),
    touches: [
      if (down != null) TouchSample(down, 0.25, 0.25, 'DOWN'),
      if (up != null) TouchSample(up, 0.5, 0.75, 'UP'),
    ],
    sensors: sensors,
    start: down ?? 0,
    end: up ?? (down ?? 0),
    clockErrorMs: 1,
    platform: 'test',
    model: 'test',
    osVersion: 'test',
    captureMode: legacy
        ? TrialRecord.legacyMode
        : fiveSeconds
            ? TrialRecord.fixedWindow5Mode
            : TrialRecord.fixedWindowMode,
    buttonT0Monotonic: legacy ? null : 100.0,
    captureStartMonotonic: legacy ? null : fiveSeconds ? 100.0 : 100.5,
    captureEndMonotonic: legacy ? null : fiveSeconds ? 105.0 : 104.5,
    actualTouchDown: down,
    actualTouchUp: up,
    windowComplete: legacy ? false : windowComplete,
    windowError: windowError,
    buttonDispatchDelayMs: dispatchDelayMs,
    hitRadiusNorm: hitRadiusNorm,
  );
}

Future<Map<String, String>> zipContents(File file) async {
  final archive = ZipDecoder().decodeBytes(await file.readAsBytes());
  return {
    for (final entry in archive.files)
      if (entry.isFile) entry.name: utf8.decode(entry.content as List<int>),
  };
}

void main() {
  test('five-second SHORT trial exports only the complete fixed window',
      () async {
    final dir = await Directory.systemTemp.createTemp('five_second_test_');
    addTearDown(() => dir.delete(recursive: true));
    final store = SessionStorage(dir);
    final short = fixture(
      id: 'T500',
      fiveSeconds: true,
      target: const [8, 5, 2],
      visitNodes: const [8, 5, 2],
    );
    await store.saveTrial(short);
    await store.saveTrial(fixture(id: 'T400', fiveSeconds: false));
    expect(TrialSummary.fromRecord(short).status, TrialStatus.success);
    final zip = await zipContents(
      await store.exportSelected({'T500'}, diagnostics: false),
    );
    final trials = const LineSplitter().convert(zip['trials.csv']!);
    final sensors = const LineSplitter().convert(zip['sensor_events.csv']!);
    expect(trials.first, trialHeader);
    expect(sensors.first, sensorHeader);
    expect(trials.length, 2);
    expect(trials[1], contains('8-5-2'));
    expect(sensors.skip(1).every((s) => s.startsWith('T500,')), true);
    final times = sensors.skip(1).map((s) => double.parse(s.split(',')[1]));
    expect(times.every((t) => t >= 100.0 && t < 105.0), true);
    expect(times.last, greaterThan(104.9));
    expect(zip['fixed_window_metadata.csv'], contains('fixed_window_5s_v1'));
    expect(zip['fixed_window_metadata.csv'], contains(',0.0,5.0,true,'));
    await expectLater(
      store.exportSelected({'T400'}, diagnostics: false),
      throwsStateError,
    );
    final old = await zipContents(
      await store.exportSelected({'T400'}, diagnostics: false, legacy: true),
    );
    expect(old['trials.csv'], contains('T400'));
    expect(old['trials.csv'], isNot(contains('T500')));
    expect(old['fixed_window_metadata.csv'], contains('fixed_window_v1'));
  });

  test('touch before 0.5 seconds remains a failed five-second trial', () {
    final early = fixture(
      fiveSeconds: true,
      target: const [8, 5, 2],
      visitNodes: const [8, 5, 2],
      down: 100.2,
      up: 101.0,
    );
    expect(TrialSummary.fromRecord(early).status, TrialStatus.failed);
    expect(assess(early).reason, 'EARLY_TOUCH');
  });
  test('capture radius is stored per trial without rewriting old records',
      () async {
    final root = await Directory.systemTemp.createTemp('radius_test_');
    addTearDown(() => root.delete(recursive: true));
    final store = SessionStorage(root);
    await store.saveTrial(fixture(
      id: 'T080',
      target: const [2, 3, 6, 9],
      hitRadiusNorm: 0.08,
    ));
    final loaded = await store.loadTrial('T080');
    expect(loaded!.hitRadiusNorm, 0.08);
    final oldJson = fixture(id: 'T120').toJson()..remove('hit_radius_norm');
    expect(TrialRecord.fromJson(oldJson).hitRadiusNorm, 0.12);
    final zip = await zipContents(
      await store.exportSelected({'T080'}, diagnostics: true),
    );
    final rows = const LineSplitter()
        .convert(zip['failed_trial_diagnostics.csv']!)
        .where((row) => row.isNotEmpty)
        .toList();
    final radiusIndex = rows.first.split(',').indexOf('hit_radius_norm');
    expect(radiusIndex, greaterThanOrEqualTo(0));
    expect(rows[1].split(',')[radiusIndex], '0.08');
  });
  test('participant and pattern ZIP names retain separate CSV records',
      () async {
    final root = await Directory.systemTemp.createTemp('participant_zip_test_');
    addTearDown(() => root.delete(recursive: true));
    final store = SessionStorage(root);
    await store.saveTrial(fixture(id: 'T301', participantId: 'P1'));
    await store.saveTrial(fixture(id: 'T302', participantId: 'P2'));
    for (final (id, participant) in [('T301', 'P1'), ('T302', 'P2')]) {
      final file = await store.exportSelected({id}, diagnostics: false);
      expect(file.uri.pathSegments.last, startsWith('${participant}_'));
      expect(file.uri.pathSegments.last, contains('_1-2-5-8_'));
      final zip = await zipContents(file);
      final rows = const LineSplitter().convert(zip['trials.csv']!);
      expect(rows, hasLength(2));
      expect(rows.last, contains('$id,$participant,'));
      expect(rows.last, isNot(contains(participant == 'P1' ? 'T302' : 'T301')));
    }
  });

  test('pattern batches make separate ZIPs with unchanged ML headers',
      () async {
    final root = await Directory.systemTemp.createTemp('pattern_batches_');
    addTearDown(() => root.delete(recursive: true));
    final store = SessionStorage(root);
    await store.saveTrial(fixture(id: 'T201'));
    await store.saveTrial(fixture(
      id: 'T202',
      target: const [1, 4, 7, 8],
      visitNodes: const [1, 4, 7, 8],
    ));
    final groups = groupTrials(
        (await store.loadSummaries()).where((s) => s.fixedWindowSuccess));
    expect(groups.keys, {'1-2-5-8', '1-4-7-8'});
    for (final entries in groups.values) {
      final content = await zipContents(await store.exportSelected(
        entries.map((s) => s.id).toSet(),
        diagnostics: false,
      ));
      final trials = const LineSplitter().convert(content['trials.csv']!);
      final sensors =
          const LineSplitter().convert(content['sensor_events.csv']!);
      expect(trials.first, trialHeader);
      expect(sensors.first, sensorHeader);
      expect(trials.length, 2);
      expect(trials.last, contains(entries.single.id));
      expect(
          sensors.skip(1).every(
              (row) => row.isEmpty || row.startsWith('${entries.single.id},')),
          true);
    }
  });

  test('as-of join never uses a future sample and excludes stale/missing', () {
    final joined = joinSensors(
      const [
        SensorSample(100.0, 1, 2, 3, 'ACCEL'),
        SensorSample(100.01, 4, 5, 6, 'GYRO'),
        SensorSample(100.1, 7, 8, 9, 'ACCEL'),
      ],
      100,
      101,
    );
    expect(joined.rows.length, 1);
    expect(joined.rows.first.time, 100.01);
    expect(joined.rows.first.ax, 1);
    expect(joined.missing, 2);
  });
  test(
    'single result export contains one success trial and only its sensor rows',
    () async {
      final dir = await Directory.systemTemp.createTemp('pattern_test_');
      addTearDown(() async => dir.delete(recursive: true));
      final store = SessionStorage(dir);
      final t = fixture();
      await store.saveTrial(t);
      await store.saveTrial(t);
      await store.saveTrial(fixture(id: 'T002'));
      await store.saveTrial(fixture(id: 'T003', target: const [2, 3, 6, 9]));
      await store.saveTrial(fixture(id: 'T004', withSensors: false));
      final artifact =
          await store.createExportSelected({'T001'}, diagnostics: false);
      final file = artifact.zip;
      expect(artifact.targetPatterns, {'1-2-5-8'});
      expect(
          file.uri.pathSegments.last,
          matches(RegExp(
              r'^P1_[0-9a-f]{8}_1-2-5-8_[0-9a-f]{12}_[0-9]{4}_[0-9]{4}_[0-9a-f]{12}\.zip$')));
      final zip = await zipContents(file);
      expect(zip['export_manifest.csv'], contains(file.uri.pathSegments.last));
      expect(zip['export_manifest.csv'], contains(artifact.exportId));
      final trials = const LineSplitter()
          .convert(zip['trials.csv']!)
          .where((s) => s.isNotEmpty)
          .toList();
      final sensors = const LineSplitter()
          .convert(zip['sensor_events.csv']!)
          .where((s) => s.isNotEmpty)
          .toList();
      expect(trials.first, trialHeader);
      expect(sensors.first, sensorHeader);
      expect(trials.length, 2);
      expect(trials[1], contains('1-2-5-8'));
      expect(sensors.length, greaterThan(90));
      expect(sensors.skip(1).every((s) => s.startsWith('T001,')), true);
      final times = sensors
          .skip(1)
          .map((row) => double.parse(row.split(',')[1]))
          .toList();
      expect(times.every((t) => t >= 100.0 && t < 105.0), true);
      expect(times.last, greaterThan(101.1));
      expect(zip['fixed_window_metadata.csv'], contains('fixed_window_5s_v1'));
      expect((await store.loadSummaries()).length, 4);
      expect(
        (await store.loadSummaries())
            .where((s) => s.status == TrialStatus.success)
            .length,
        2,
      );
    },
  );
  test('failed and review result exports use diagnostic files only', () async {
    final dir = await Directory.systemTemp.createTemp('pattern_test_');
    addTearDown(() async => dir.delete(recursive: true));
    final store = SessionStorage(dir);
    await store.saveTrial(fixture(id: 'T010', target: const [2, 3, 6, 9]));
    await store.saveTrial(fixture(id: 'T011', withSensors: false));
    for (final id in ['T010', 'T011']) {
      final zip = await zipContents(
        await store.exportSelected({id}, diagnostics: true),
      );
      expect(zip.keys, contains('failed_trial_diagnostics.csv'));
      expect(zip.keys, isNot(contains('trials.csv')));
      expect(zip.keys, isNot(contains('sensor_events.csv')));
      expect(zip['failed_trial_diagnostics.csv']!, contains(id));
      expect(
        zip['failed_trial_diagnostics.csv']!,
        isNot(contains(id == 'T010' ? 'T011' : 'T010')),
      );
    }
  });
  test(
    'export cancellation and retry do not change stored records or counts',
    () async {
      final dir = await Directory.systemTemp.createTemp('pattern_test_');
      addTearDown(() async => dir.delete(recursive: true));
      final store = SessionStorage(dir);
      await store.saveTrial(fixture());
      final original =
          await File('${store.records.path}/T001.json').readAsBytes();
      await expectLater(
        store.exportSelected(
          {'T001'},
          diagnostics: false,
          cancelled: () => true,
        ),
        throwsA(isA<ExportCancelled>()),
      );
      await store.exportSelected({'T001'}, diagnostics: false);
      await store.exportSelected({'T001'}, diagnostics: false);
      expect(
        await File('${store.records.path}/T001.json').readAsBytes(),
        original,
      );
      expect((await store.loadSummaries()).length, 1);
      expect(
        (await store.exports
            .list()
            .where((e) => e.path.endsWith('.tmp'))
            .toList()),
        isEmpty,
      );
    },
  );
  test(
    'legacy unknown remains review; folder and trial selection deduplicate',
    () {
      final legacy = TrialSummary.legacyUnknown('T099');
      expect(legacy.status, TrialStatus.review);
      expect(legacy.reason, 'LEGACY_UNKNOWN');
      final success = TrialSummary.fromRecord(fixture());
      final failed = TrialSummary.fromRecord(
        fixture(id: 'T002', target: const [2, 3, 6, 9]),
      );
      final review = TrialSummary.fromRecord(
        fixture(id: 'T003', withSensors: false),
      );
      final group = groupTrials([success, failed, review]);
      expect(
        group['1-2-5-8']!.where((s) => s.status == TrialStatus.success).length,
        1,
      );
      expect(
        selectedIds([
          success,
          failed,
          review
        ], {
          '1-2-5-8'
        }, {
          success.id,
        }).length,
        2,
      );
    },
  );
  test(
    'old CSV-only trial is indexed as review without altering files',
    () async {
      final dir = await Directory.systemTemp.createTemp('pattern_test_');
      addTearDown(() async => dir.delete(recursive: true));
      final old = Directory('${dir.path}/exports/g_old');
      await old.create(recursive: true);
      final csv = File('${old.path}/trials.csv');
      await csv.writeAsString(
        '$trialHeader\nT099,P1,1-2-5-8,"[1,2,3,4]",phone,right,seated\n',
      );
      await File('${dir.path}/active.txt').writeAsString('g_old');
      final store = SessionStorage(dir);
      for (var i = 0; i < 2; i++) {
        final summaries = await store.loadSummaries();
        expect(summaries.length, 1);
        expect(summaries.single.status, TrialStatus.review);
        expect(summaries.single.reason, 'LEGACY_UNKNOWN');
      }
      expect(await csv.readAsString(), contains('T099'));
    },
  );
  test('early and late UP use the same five-second sensor window', () {
    final early = assess(fixture(up: 101.4));
    final late = assess(fixture(up: 103.0));
    expect(early.eligible, true);
    expect(late.eligible, true);
    expect(early.joined.rows.first.time, late.joined.rows.first.time);
    expect(early.joined.rows.last.time, late.joined.rows.last.time);
    expect(early.joined.rows.last.time, greaterThan(103.0));
  });
  test('early touch, timeout, no input, and late start are excluded', () {
    final early = TrialSummary.fromRecord(fixture(down: 100.2));
    final timeout = TrialSummary.fromRecord(fixture(up: null));
    final noInput = TrialSummary.fromRecord(fixture(down: null, up: null));
    final delayed = TrialSummary.fromRecord(fixture(dispatchDelayMs: 120));
    final notReady = TrialSummary.fromRecord(fixture(withSensors: false));
    final lateDeadline = TrialSummary.fromRecord(
      fixture(windowComplete: false, windowError: 'WINDOW_DEADLINE_DELAY'),
    );
    expect(early.status, TrialStatus.failed);
    expect(early.reason, 'EARLY_TOUCH');
    expect(timeout.status, TrialStatus.failed);
    expect(timeout.reason, 'WINDOW_TIMEOUT');
    expect(noInput.status, TrialStatus.failed);
    expect(noInput.reason, 'NO_INPUT_IN_WINDOW');
    expect(delayed.status, TrialStatus.review);
    expect(delayed.reason, 'BUTTON_DISPATCH_DELAY');
    expect(notReady.status, TrialStatus.review);
    expect(notReady.reason, 'SENSOR_NOT_READY_IN_WINDOW');
    expect(lateDeadline.status, TrialStatus.review);
    expect(lateDeadline.reason, 'WINDOW_DEADLINE_DELAY');
  });
  test('legacy stays stored and requires explicit separate export', () async {
    final dir = await Directory.systemTemp.createTemp('pattern_test_');
    addTearDown(() async => dir.delete(recursive: true));
    final store = SessionStorage(dir);
    await store.saveTrial(fixture(id: 'T101', legacy: true));
    await store.saveTrial(fixture(id: 'T102'));
    final summaries = await store.loadSummaries();
    expect(summaries.where((s) => s.legacySuccess).length, 1);
    expect(summaries.where((s) => s.fixedWindowSuccess).length, 1);
    await expectLater(
      store.exportSelected({'T101'}, diagnostics: false),
      throwsStateError,
    );
    final fixed = await zipContents(
      await store.exportSelected({'T102'}, diagnostics: false),
    );
    expect(fixed['trials.csv'], isNot(contains('T101')));
    final legacy = await zipContents(
      await store.exportSelected({'T101'}, diagnostics: false, legacy: true),
    );
    expect(legacy['trials.csv'], contains('T101'));
    expect(legacy['trials.csv'], isNot(contains('T102')));
    expect(legacy['export_manifest.csv'], contains('legacy_touch_cropped'));
    expect((await store.loadSummaries()).length, 2);
  });
}
