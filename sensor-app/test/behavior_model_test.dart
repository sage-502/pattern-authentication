import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pattern_sensor_collector/behavior_auth_params.dart';
import 'package:pattern_sensor_collector/enrollment_repository.dart';
import 'package:pattern_sensor_collector/model.dart';
import 'package:pattern_sensor_collector/storage.dart';

import 'enrollment_repository_test.dart' show capture;

/// A touch-window attempt whose motion depends on [tilt].
TrialRecord moving(String userId, int index, double tilt, {int salt = 0}) {
  final base = capture(userId, 1, index, idSalt: salt);
  final sensors = <SensorSample>[];
  for (var i = 0; i < 50; i++) {
    final t = 100.6 + i * 0.01;
    sensors.add(SensorSample(t, tilt * i / 50, 2, 9.8, 'ACCEL'));
    sensors.add(SensorSample(t + 0.005, tilt * 0.1, 0.2, 0.3, 'GYRO'));
  }
  return TrialRecord(
    id: base.id,
    sessionId: base.sessionId,
    participantId: base.participantId,
    deviceId: base.deviceId,
    hand: base.hand,
    posture: base.posture,
    holdingHand: base.holdingHand,
    target: base.target,
    visits: base.visits,
    touches: base.touches,
    sensors: sensors,
    start: base.start,
    end: base.end,
    clockErrorMs: 0,
    index: base.index,
    platform: base.platform,
    model: base.model,
    osVersion: base.osVersion,
    captureMode: base.captureMode,
    actualTouchDown: base.actualTouchDown,
    actualTouchUp: base.actualTouchUp,
    windowComplete: true,
    hitRadiusNorm: base.hitRadiusNorm,
    source: base.source,
    sensorTimestampBasis: base.sensorTimestampBasis,
  );
}

Future<(SessionStorage, EnrollmentRepository)> _enrolled() async {
  final root = await Directory.systemTemp.createTemp('behavior_model_');
  addTearDown(() => root.delete(recursive: true));
  final storage = SessionStorage(root);
  final repository = EnrollmentRepository(storage);
  await repository.createUser(userId: 'user001', displayName: '사용자 A');
  await repository.confirmPattern('user001', [1, 2, 3]);
  for (var i = 1; i <= 5; i++) {
    await repository.saveCapture('user001', 1, capture('user001', 1, i));
  }
  await repository.acknowledgeRegrip('user001');
  for (var i = 1; i <= 5; i++) {
    await repository.saveCapture('user001', 2, capture('user001', 2, i));
  }
  return (storage, repository);
}

void main() {
  test('training needs enough samples', () async {
    final root = await Directory.systemTemp.createTemp('behavior_model_few_');
    addTearDown(() => root.delete(recursive: true));
    final repository = EnrollmentRepository(SessionStorage(root));
    await repository.createUser(userId: 'user001', displayName: '사용자 A');
    await repository.confirmPattern('user001', [1, 2, 3]);
    await repository.saveCapture('user001', 1, capture('user001', 1, 1));
    await expectLater(repository.trainModel('user001'), throwsStateError);
    expect((await repository.getUser('user001'))!.model, isNull);
  });

  test('legacy ten-trial enrollment remains stored but cannot fit v4.2',
      () async {
    final (storage, repository) = await _enrolled();
    final set = await repository.trainingSet('user001');
    expect(set.enrollment, 10);
    expect(set.vectors, hasLength(10));
    expect(
        set.vectors.every(
            (v) => v.sequence.length == behaviorSeqLen && v.timing.isNotEmpty),
        isTrue);

    await expectLater(repository.trainModel('user001'), throwsStateError);
    final profile = (await repository.getUser('user001'))!;
    expect(profile.model, isNull);
    expect(profile.modelStatus, '미학습');
    await expectLater(
        repository.verifyBehavior(
            'user001', capture('user001', 1, 1, idSalt: 9)),
        throwsStateError);

    await repository.deleteUser('user001');
    final models = Directory('${storage.root.path}/models');
    expect(await models.exists() ? models.listSync() : const [], isEmpty);
  });

  test('verification without a model is refused', () async {
    final (_, repository) = await _enrolled();
    await expectLater(
        repository.verifyBehavior('user001', capture('user001', 1, 1)),
        throwsStateError);
  });
}
