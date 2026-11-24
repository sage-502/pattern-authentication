import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pattern_sensor_collector/enrollment_repository.dart';
import 'package:pattern_sensor_collector/model.dart';
import 'package:pattern_sensor_collector/storage.dart';

import 'enrollment_repository_test.dart' show capture;

/// A successful login capture of [userId] stored under the login session.
TrialRecord loginCapture(String userId, int n,
    {List<int> pattern = const [1, 2, 3]}) {
  final base = capture(userId, 1, 1, pattern: pattern, idSalt: 100 + n);
  return TrialRecord(
    id: base.id,
    sessionId: loginSessionId(userId),
    participantId: base.participantId,
    deviceId: base.deviceId,
    hand: base.hand,
    posture: base.posture,
    holdingHand: base.holdingHand,
    target: base.target,
    visits: base.visits,
    touches: base.touches,
    sensors: base.sensors,
    start: base.start,
    end: base.end,
    clockErrorMs: 0,
    index: 1,
    platform: base.platform,
    model: base.model,
    osVersion: base.osVersion,
    captureMode: base.captureMode,
    actualTouchDown: base.actualTouchDown,
    actualTouchUp: base.actualTouchUp,
    windowComplete: true,
    hitRadiusNorm: base.hitRadiusNorm,
    source: TrialRecord.loginSource,
    sensorTimestampBasis: base.sensorTimestampBasis,
  );
}

Future<(SessionStorage, EnrollmentRepository)> _repository() async {
  final root = await Directory.systemTemp.createTemp('login_accumulation_');
  addTearDown(() => root.delete(recursive: true));
  final storage = SessionStorage(root);
  return (storage, EnrollmentRepository(storage));
}

Future<void> _enroll(EnrollmentRepository repository) async {
  await repository.createUser(userId: 'user001', displayName: '사용자 A');
  await repository.confirmPattern('user001', [1, 2, 3]);
  for (var i = 1; i <= 5; i++) {
    await repository.saveCapture('user001', 1, capture('user001', 1, i));
  }
  await repository.acknowledgeRegrip('user001');
  for (var i = 1; i <= 5; i++) {
    await repository.saveCapture('user001', 2, capture('user001', 2, i));
  }
}

TrialRecord _calibrated(TrialRecord base, int user, int attempt) {
  final down = base.actualTouchDown!;
  final baseline = <SensorSample>[];
  for (var i = 0; i < 70; i++) {
    final t = down - 0.7 + i * 0.01;
    baseline.add(SensorSample(t, 0, 0, 9.8, 'ACCEL'));
    baseline.add(SensorSample(t + 0.005, 0.01, 0.01, 0.01, 'GYRO'));
  }
  final motion = [
    for (final s in base.sensors)
      SensorSample(
          s.time,
          s.x + user * 0.25 + attempt * 0.001 + (s.time - down) * 0.1,
          s.y + user * 0.05,
          s.z,
          s.type),
  ];
  return TrialRecord(
    id: '${base.id}_u$user',
    sessionId: base.sessionId,
    participantId: base.participantId,
    deviceId: base.deviceId,
    hand: base.hand,
    posture: base.posture,
    holdingHand: base.holdingHand,
    target: base.target,
    visits: base.visits,
    touches: base.touches,
    sensors: [...baseline, ...motion],
    start: base.start,
    end: base.end,
    clockErrorMs: base.clockErrorMs,
    index: base.index,
    platform: base.platform,
    model: base.model,
    osVersion: base.osVersion,
    captureMode: TrialRecord.touchCalibratedMode,
    actualTouchDown: base.actualTouchDown,
    actualTouchUp: base.actualTouchUp,
    windowComplete: true,
    hitRadiusNorm: base.hitRadiusNorm,
    source: base.source,
    sensorTimestampBasis: base.sensorTimestampBasis,
  );
}

Future<void> _enrollCalibrated(
    EnrollmentRepository repository, int user) async {
  final id = 'user00$user';
  await repository.createUser(userId: id, displayName: '사용자 $user');
  await repository.confirmPattern(id, [1, 2, 3]);
  for (var i = 1; i <= 5; i++) {
    await repository.saveCapture(
        id, 1, _calibrated(capture(id, 1, i), user, i));
  }
  await repository.acknowledgeRegrip(id);
  for (var i = 1; i <= 5; i++) {
    await repository.saveCapture(
        id, 2, _calibrated(capture(id, 2, i), user, 5 + i));
  }
}

void main() {
  test('one calibrated user trains v4.2 and exports their data', () async {
    final (_, repository) = await _repository();
    const id = 'user001';
    await _enrollCalibrated(repository, 1);
    for (var n = 1; n <= 30; n++) {
      final result = await repository.saveLoginCapture(
          id, _calibrated(loginCapture(id, n), 1, 10 + n));
      if (n == 30) expect(result.autoTrained, isNotNull);
    }
    final profile = (await repository.getUser(id))!;
    expect(profile.model!.trainedWithCount, 40);
    expect(profile.model!.threshold, -3.294446507886175);
    final decision = await repository.verifyBehavior(
        id, _calibrated(loginCapture(id, 31), 1, 41));
    expect(decision.score.isFinite, isTrue);
    expect(decision.threshold, -3.294446507886175);
    final file = await repository.exportModelTrainingData(id);
    final files = {
      for (final entry in ZipDecoder().decodeBytes(await file.readAsBytes()))
        entry.name: utf8.decode(entry.content as List<int>),
    };
    final manifest =
        jsonDecode(files['manifest.json']!) as Map<String, dynamic>;
    expect(manifest['selected_count'], 40);
    expect(files['training_trials.csv']!.trim().split('\r\n'), hasLength(41));
    expect(files['model_features.csv']!.trim().split('\r\n'), hasLength(41));
    expect(files['pre_touch_sensor_rows.csv'], contains('timestamp'));
  }, timeout: const Timeout(Duration(minutes: 2)));
  test('legacy captures accumulate to 40 but cannot train v4.2', () async {
    final (storage, repository) = await _repository();
    await _enroll(repository);
    var profile = (await repository.getUser('user001'))!;
    expect(profile.validDataCount, 10);
    expect(profile.collectsLoginData, isTrue);

    for (var n = 1; n <= 29; n++) {
      final r = await repository.saveLoginCapture(
          'user001', loginCapture('user001', n));
      expect(r.stored, isTrue);
      expect(r.validDataCount, 10 + n);
      expect(r.autoTrained, isNull);
    }
    profile = (await repository.getUser('user001'))!;
    expect(profile.validDataCount, 39);
    expect(profile.model, isNull, reason: 'no automatic training below 40');

    // A single user's old touch-only captures cannot fit v4.2.
    final reached = await repository.saveLoginCapture(
        'user001', loginCapture('user001', 30));
    expect(reached.stored, isTrue);
    expect(reached.validDataCount, 40);
    expect(reached.autoTrained, isNull);
    expect(reached.autoTrainError, isNotNull);
    profile = (await repository.getUser('user001'))!;
    expect(profile.collectsLoginData, isFalse);
    expect(profile.model, isNull);

    // Beyond 40: nothing is stored and the model is not retrained.
    final beyond = await repository.saveLoginCapture(
        'user001', loginCapture('user001', 31));
    expect(beyond.stored, isFalse);
    expect(beyond.validDataCount, 40);
    expect(beyond.autoTrained, isNull);
    profile = (await repository.getUser('user001'))!;
    expect(profile.loginRecordIds, hasLength(30));
    expect(profile.model, isNull);
    expect(await storage.loadTrial(loginCapture('user001', 31).id), isNull);

    await expectLater(repository.trainModel('user001'), throwsStateError);

    // Deleting the user removes the stored login captures too.
    await repository.deleteUser('user001');
    expect(await storage.loadTrial(loginCapture('user001', 1).id), isNull);
  });

  test('users who have not finished enrollment do not collect login data',
      () async {
    final (_, repository) = await _repository();
    await repository.createUser(userId: 'user001', displayName: '사용자 A');
    await repository.confirmPattern('user001', [1, 2, 3]);
    final r = await repository.saveLoginCapture(
        'user001', loginCapture('user001', 1));
    expect(r.stored, isFalse);
    expect((await repository.getUser('user001'))!.loginRecordIds, isEmpty);
  });

  test('a login capture with another pattern is refused', () async {
    final (_, repository) = await _repository();
    await _enroll(repository);
    await expectLater(
        repository.saveLoginCapture(
            'user001', loginCapture('user001', 1, pattern: [1, 4, 7])),
        throwsStateError);
    expect((await repository.getUser('user001'))!.validDataCount, 10);
  });

  test(
      'login phase: pattern only below 40, behavior with a model, held without',
      () {
    EnrollmentProfile profile({required int imported, bool model = false}) =>
        EnrollmentProfile(
          userId: 'u',
          displayName: 'u',
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
          hasPattern: true,
          regripAcknowledged: true,
          patternVerifierRef: 'ref',
          records: const [],
          importedTrialCount: imported,
          model: model
              ? BehaviorModelInfo(
                  trainedAt: DateTime.utc(2026),
                  trainedWithCount: 10,
                  enrollmentCount: 10,
                  importedCount: 0,
                  skipped: 0,
                  threshold: -2)
              : null,
        );
    expect(loginPhaseOf(profile(imported: 39, model: true)),
        LoginPhase.patternOnly);
    expect(loginPhaseOf(profile(imported: 39)), LoginPhase.patternOnly);
    expect(loginPhaseOf(profile(imported: 40)), LoginPhase.modelNotReady);
    expect(
        loginPhaseOf(profile(imported: 40, model: true)), LoginPhase.behavior);
  });

  test('a legacy import reaches 40 but cannot train v4.2', () async {
    final (_, repository) = await _repository();
    await _enroll(repository);
    final first = await repository
        .importTrainingZip('user001', _touchZip(0, 29), sourceName: 'a.zip');
    expect(first.imported, 29);
    expect(first.autoTrained, isNull);
    expect((await repository.getUser('user001'))!.validDataCount, 39);

    final second = await repository
        .importTrainingZip('user001', _touchZip(29, 5), sourceName: 'b.zip');
    expect(second.autoTrained, isNull);
    expect(second.autoTrainError, isNotNull);

    final third = await repository
        .importTrainingZip('user001', _touchZip(34, 3), sourceName: 'c.zip');
    expect(third.imported, 3);
    expect(third.autoTrained, isNull, reason: 'no retraining after 40');
    expect((await repository.getUser('user001'))!.model, isNull);
  });

  test('training uses the first 40 valid data in arrival order', () async {
    final (_, repository) = await _repository();
    await _enroll(repository);
    // 10 enrollment + 40 imported -> 50 valid; training takes 10 + first 30.
    final r = await repository.importTrainingZip('user001', _touchZip(0, 40),
        sourceName: 'a.zip');
    expect(r.autoTrained, isNull);
    expect(r.autoTrainError, isNotNull);
    final set = await repository.trainingSet('user001');
    expect(set.vectors, hasLength(40));
    expect(set.available, 50);
  });

  test('cannot export legacy records as v4.2 training inputs', () async {
    final (_, repository) = await _repository();
    await _enroll(repository);
    await repository.importTrainingZip('user001', _touchZip(0, 40),
        sourceName: 'a.zip');

    await expectLater(
        repository.exportModelTrainingData('user001'), throwsStateError);
  });

  test(
      'arrival order spans sources: enrollment, then logins, then a later import',
      () async {
    final (_, repository) = await _repository();
    await _enroll(repository);
    for (var n = 1; n <= 29; n++) {
      await repository.saveLoginCapture('user001', loginCapture('user001', n));
    }
    final r = await repository.importTrainingZip('user001', _touchZip(0, 5),
        sourceName: 'late.zip');
    expect(r.autoTrained, isNull);
    expect(r.autoTrainError, isNotNull);
    final set = await repository.trainingSet('user001');
    expect(set.enrollment, 10);
    expect(set.login, 29);
    expect(set.imported, 1);
    expect(set.available, 44);
  });
}

/// Touch-window research export with [count] trials of pattern 1-2-3.
Uint8List _touchZip(int from, int count) {
  final trials = StringBuffer(
      'trial_id,participant_id,pattern,node_timestamps,device_id,hand,posture\r\n');
  final sensors = StringBuffer('trial_id,timestamp,ax,ay,az,gx,gy,gz\r\n');
  final meta = StringBuffer('trial_id,actual_touch_down,actual_touch_up\r\n');
  for (var n = from; n < from + count; n++) {
    final id = 'T17949${n.toString().padLeft(8, '0')}_imp';
    final t0 = 1000.0 + n * 10;
    trials.write(
        '$id,A,1-2-3,"[${t0 + 0.05},${t0 + 0.2},${t0 + 0.35}]",B,right,seated\r\n');
    for (var i = 0; i < 50; i++) {
      final t = t0 + i * 0.01;
      sensors.write('$id,$t,1,2,9.8,0.1,0.2,${0.3 + (n % 3) * 0.01}\r\n');
    }
    meta.write('$id,$t0,${t0 + 0.49}\r\n');
  }
  final archive = Archive();
  void add(String name, String text) {
    final bytes = utf8.encode(text);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  add('trials.csv', trials.toString());
  add('sensor_events.csv', sensors.toString());
  add('fixed_window_metadata.csv', meta.toString());
  return Uint8List.fromList(ZipEncoder().encode(archive));
}
