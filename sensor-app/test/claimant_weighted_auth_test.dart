import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:pattern_sensor_collector/claimant_weighted_auth.dart';
import 'package:pattern_sensor_collector/model.dart';

void main() {
  TrialRecord trial({bool calibrated = true}) {
    const down = 100.7, up = 101.2;
    final samples = <SensorSample>[];
    for (var i = 0; i <= 120; i++) {
      final t = 100 + i * 0.01;
      final active = t >= down;
      samples.add(SensorSample(
          t, active ? 1.0 + i * 0.01 : 0.0, active ? 0.5 : 0.0, 9.8, 'ACCEL'));
      samples.add(SensorSample(t + 0.001, active ? 0.2 : 0.01,
          active ? 0.1 : 0.01, active ? 0.05 : 0.01, 'GYRO'));
    }
    return TrialRecord(
      id: 'T1',
      sessionId: 'test',
      participantId: 'u',
      deviceId: 'phone',
      hand: 'unknown',
      posture: 'unknown',
      holdingHand: 'unknown',
      target: const [1, 2, 3],
      visits: const [
        NodeVisit(1, down, 'touch_detected', false),
        NodeVisit(2, 100.9, 'touch_detected', false),
        NodeVisit(3, 101.1, 'touch_detected', false)
      ],
      touches: const [
        TouchSample(down, 0, 0, 'DOWN'),
        TouchSample(up, 1, 0, 'UP')
      ],
      sensors: samples,
      start: down,
      end: up,
      clockErrorMs: 0,
      index: 1,
      platform: 'android',
      model: 'test',
      osVersion: 'test',
      captureMode: calibrated
          ? TrialRecord.touchCalibratedMode
          : TrialRecord.touchBoundedMode,
      actualTouchDown: down,
      actualTouchUp: up,
    );
  }

  test('calibrated capture yields the ordered 23 features', () {
    final values = weightedFeaturesFromTrial(trial());
    expect(values, hasLength(23));
    expect(values.every((v) => v.isFinite), isTrue);
    expect(values.last, closeTo(0.5, 1e-12));
    expect(() => weightedFeaturesFromTrial(trial(calibrated: false)),
        throwsA(isA<WeightedFeatureException>()));
  });

  test('one user uses the fixed research threshold and serializes a template',
      () {
    final samples = [
      for (var n = 0; n < 40; n++)
        [for (var c = 0; c < 23; c++) c * 0.01 + n * 0.001],
    ];
    final model = fitWeightedClaimant(samples);
    expect(model.threshold, weightedThreshold);
    expect(model.weight, weightedReferenceWeights);
    expect(
        model.score(samples[39]),
        greaterThan(model.score([
          for (final x in samples[39]) x + 2,
        ])));
    final restored = WeightedClaimantModel.fromJson(
        jsonDecode(jsonEncode(model.toJson())) as Map<String, dynamic>);
    expect(
        restored.score(samples[39]), closeTo(model.score(samples[39]), 1e-12));
  });
}
