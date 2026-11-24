import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pattern_sensor_collector/enrollment_repository.dart';
import 'package:pattern_sensor_collector/model.dart';
import 'package:pattern_sensor_collector/storage.dart';

/// v3 touch-bounded capture: sensors only inside [touch down, touch up].
TrialRecord capture(String userId, int session, int index,
    {List<int> pattern = const [1, 2, 3],
    bool sensorsPresent = true,
    bool sensorBeforeTouch = false,
    int idSalt = 0}) {
  const down = 100.6, up = 101.1;
  final samples = <SensorSample>[];
  if (sensorBeforeTouch) {
    samples.add(const SensorSample(down - 0.2, 1, 2, 9.8, 'ACCEL'));
  }
  if (sensorsPresent) {
    for (var i = 0; i < 50; i++) {
      final time = down + i * 0.01;
      samples.add(SensorSample(time, 1, 2, 9.8, 'ACCEL'));
      samples.add(SensorSample(time + 0.005, 0.1, 0.2, 0.3, 'GYRO'));
    }
  }
  final idTime =
      DateTime.utc(2026, 11, 17).microsecondsSinceEpoch +
          session * 100 +
          index +
          idSalt * 10000;
  return TrialRecord(
    id: 'T$idTime',
    sessionId: enrollmentSessionId(userId, session),
    participantId: userId,
    deviceId: 'test-phone',
    hand: 'unknown',
    posture: 'unknown',
    holdingHand: 'unknown',
    target: pattern,
    visits: [
      for (var i = 0; i < pattern.length; i++)
        NodeVisit(pattern[i], down + i * 0.1, 'touch_detected', false),
    ],
    touches: const [
      TouchSample(down, 0.25, 0.25, 'DOWN'),
      TouchSample(up, 0.75, 0.25, 'UP'),
    ],
    sensors: samples,
    start: down,
    end: up,
    clockErrorMs: 0,
    index: index,
    platform: 'android',
    model: 'test',
    osVersion: 'test',
    captureMode: TrialRecord.touchBoundedMode,
    actualTouchDown: down,
    actualTouchUp: up,
    windowComplete: true,
    hitRadiusNorm: 0.08,
    source: TrialRecord.enrollmentSource,
    sensorTimestampBasis: 'elapsedRealtimeNanos',
  );
}

/// A record saved by the earlier five-second fixed-window build.
TrialRecord legacyFixedCapture(String userId, int session, int index) {
  final samples = <SensorSample>[];
  for (var i = 0; i <= 200; i++) {
    final time = 100 + i * 0.025;
    samples.add(SensorSample(time, 1, 2, 9.8, 'ACCEL'));
    samples.add(SensorSample(time + 0.005, 0.1, 0.2, 0.3, 'GYRO'));
  }
  final idTime =
      DateTime.utc(2026, 11, 16).microsecondsSinceEpoch + session * 100 + index;
  return TrialRecord(
    id: 'T$idTime',
    sessionId: enrollmentSessionId(userId, session),
    participantId: userId,
    deviceId: 'test-phone',
    hand: 'unknown',
    posture: 'unknown',
    holdingHand: 'unknown',
    target: const [1, 2, 3],
    visits: [
      for (var i = 0; i < 3; i++)
        NodeVisit(i + 1, 100.6 + i * 0.1, 'touch_detected', false),
    ],
    touches: const [
      TouchSample(100.6, 0.25, 0.25, 'DOWN'),
      TouchSample(101.1, 0.75, 0.25, 'UP'),
    ],
    sensors: samples,
    start: 100.6,
    end: 101.1,
    clockErrorMs: 0,
    index: index,
    platform: 'android',
    model: 'test',
    osVersion: 'test',
    captureMode: TrialRecord.fixedWindow5Mode,
    buttonT0Monotonic: 100,
    captureStartMonotonic: 100,
    captureEndMonotonic: 105,
    actualTouchDown: 100.6,
    actualTouchUp: 101.1,
    windowComplete: true,
    hitRadiusNorm: 0.08,
  );
}

void main() {
  test('draft and verifier survive restart without storing the raw pattern',
      () async {
    final root = await Directory.systemTemp.createTemp('enrollment_profile_');
    addTearDown(() => root.delete(recursive: true));
    final repository = EnrollmentRepository(SessionStorage(root));
    final draft =
        await repository.createUser(userId: 'user001', displayName: '사용자 A');
    expect(draft.stage, EnrollmentStage.draft);
    expect(draft.totalCount, 0);
    await expectLater(
      repository.createUser(userId: 'user001', displayName: '다른 사용자'),
      throwsStateError,
    );
    final confirmed = await repository.confirmPattern('user001', [1, 2, 3]);
    expect(confirmed.stage, EnrollmentStage.collectingSession1);
    expect(confirmed.patternVerifierRef, isNotNull);
    expect(await repository.matchesPattern('user001', [1, 2, 3]), isTrue);
    expect(await repository.matchesPattern('user001', [1, 2, 4]), isFalse);
    final profileFile = (await Directory('${root.path}/enrollment/users')
            .list()
            .cast<File>()
            .first)
        .path;
    final profileJson = await File(profileFile).readAsString();
    final verifierJson =
        await File('${root.path}/${confirmed.patternVerifierRef}')
            .readAsString();
    expect(profileJson, isNot(contains('1-2-3')));
    expect(verifierJson, isNot(contains('1-2-3')));
    final reopened = EnrollmentRepository(SessionStorage(root));
    expect((await reopened.getUser('user001'))!.stage,
        EnrollmentStage.collectingSession1);
    expect((await reopened.getUsers()).single.displayName, '사용자 A');
  });

  test('only ten durable valid captures complete registration', () async {
    final root = await Directory.systemTemp.createTemp('enrollment_capture_');
    addTearDown(() => root.delete(recursive: true));
    final repository = EnrollmentRepository(SessionStorage(root));
    await repository.createUser(userId: 'user001', displayName: '사용자 A');
    await repository.confirmPattern('user001', [1, 2, 3]);
    await expectLater(
      repository.saveCapture(
          'user001', 1, capture('user001', 1, 1, pattern: const [1, 2, 4])),
      throwsStateError,
    );
    await expectLater(
      repository.saveCapture(
          'user001', 1, capture('user001', 1, 1, sensorsPresent: false)),
      throwsStateError,
    );
    expect((await repository.getUser('user001'))!.totalCount, 0);
    for (var index = 1; index <= 5; index++) {
      await repository.saveCapture('user001', 1, capture('user001', 1, index));
    }
    final paused = EnrollmentRepository(SessionStorage(root));
    final first = (await paused.getUser('user001'))!;
    expect(first.stage, EnrollmentStage.regripRequired);
    expect(first.session1Count, 5);
    await expectLater(
      paused.saveCapture('user001', 2, capture('user001', 2, 1)),
      throwsStateError,
    );
    await paused.acknowledgeRegrip('user001');
    for (var index = 1; index <= 5; index++) {
      await paused.saveCapture('user001', 2, capture('user001', 2, index));
    }
    final completed = (await paused.getUser('user001'))!;
    expect(completed.stage, EnrollmentStage.completed);
    expect(completed.registrationStatus, 'COMPLETED');
    expect(completed.totalCount, 10);
    expect(completed.records.map((r) => r.attemptIndex).toList(),
        [1, 2, 3, 4, 5, 1, 2, 3, 4, 5]);
    expect(completed.records.every((r) => r.captureStatus == 'SAVED'), isTrue);
    await File('${root.path}/${completed.records.last.sensorDataRef}').delete();
    final incomplete = (await paused.getUser('user001'))!;
    expect(incomplete.totalCount, 9);
    expect(incomplete.isComplete, isFalse);
  });

  test('touch-bounded quality rejects samples outside the touch window', () {
    expect(assess(capture('user001', 1, 1)).eligible, isTrue);
    expect(assess(capture('user001', 1, 1, sensorBeforeTouch: true)).reason,
        'SENSOR_OUTSIDE_TOUCH_WINDOW');
    expect(assess(capture('user001', 1, 1, sensorsPresent: false)).eligible,
        isFalse);
  });

  test('new saves require touch-bounded mode but earlier records still count',
      () async {
    final root = await Directory.systemTemp.createTemp('enrollment_modes_');
    addTearDown(() => root.delete(recursive: true));
    final storage = SessionStorage(root);
    final repository = EnrollmentRepository(storage);
    await repository.createUser(userId: 'user001', displayName: '사용자 A');
    await repository.confirmPattern('user001', [1, 2, 3]);
    await expectLater(
      repository.saveCapture('user001', 1, legacyFixedCapture('user001', 1, 1)),
      throwsStateError,
    );
    await expectLater(
      repository.saveCapture(
          'user001', 1, capture('user001', 1, 1, sensorBeforeTouch: true)),
      throwsStateError,
    );
    // Simulate data stored by the previous build before this update.
    await storage.saveTrial(legacyFixedCapture('user001', 1, 1));
    final profile = (await repository.getUser('user001'))!;
    expect(profile.session1Count, 1);
    expect(profile.records.single.isTouchBounded, isFalse);
    final next =
        await repository.saveCapture('user001', 1, capture('user001', 1, 2));
    expect(next.session1Count, 2);
    expect(next.records.last.isTouchBounded, isTrue);
    final saved = await storage.loadTrial(next.records.last.recordId);
    expect(saved!.source, TrialRecord.enrollmentSource);
    expect(saved.sensorTimestampBasis, 'elapsedRealtimeNanos');
    expect(saved.sensors.every((s) => s.time >= 100.6 && s.time <= 101.1),
        isTrue);
  });
}
