import 'dart:math' as math;

import 'model.dart';

/// App port of the 23-feature claimant-weighted distance in
/// pattern-ml/tune_claimant_weighted_distance.py (tag 4.2). The app collects
/// its own idle baseline. The experiment's common threshold is fixed in the
/// app as requested; it is not reselected from app registrations.
const weightedPipelineVersion = 'claimant_weighted_v4_2_single';
const weightedFeatures = <String>[
  'all_lax_mean',
  'all_lax_std',
  'all_lax_delta',
  'all_lay_mean',
  'all_lay_std',
  'all_lay_delta',
  'all_laz_mean',
  'all_laz_std',
  'all_laz_delta',
  'all_fgx_mean',
  'all_fgx_std',
  'all_fgx_delta',
  'all_fgy_mean',
  'all_fgy_std',
  'all_fgy_delta',
  'all_fgz_mean',
  'all_fgz_std',
  'all_fgz_delta',
  'all_acc_mag_mean',
  'all_acc_mag_std',
  'all_gyro_mag_mean',
  'all_gyro_mag_std',
  'duration',
];
const weightedEnrollmentCount = 40;
const weightedThreshold = -3.294446507886175;
// Per-feature mean of the four claimant weights in the tag 4.2 result JSON.
const weightedReferenceWeights = <double>[
  1.8013706763,
  2.6173360389,
  2.3458366121,
  2.5380068512,
  2.2049226240,
  2.1930749710,
  1.7082300903,
  2.2360671743,
  1.6897192719,
  1.6238386491,
  2.1366016131,
  2.2221195477,
  2.4024514519,
  2.4711396180,
  1.8080854556,
  1.9355023023,
  2.5395420868,
  2.2276348673,
  2.5432875628,
  2.0072061387,
  2.0834730719,
  1.9925359268,
  2.3286073545,
];

class WeightedFeatureException implements Exception {
  final String message;
  const WeightedFeatureException(this.message);
  @override
  String toString() => message;
}

List<double> weightedFeaturesFromTrial(TrialRecord trial) {
  final down = trial.actualTouchDown;
  final up = trial.actualTouchUp;
  if (down == null || up == null || up <= down) {
    throw const WeightedFeatureException('터치 구간이 없습니다.');
  }
  if (trial.captureMode != TrialRecord.touchCalibratedMode) {
    throw const WeightedFeatureException('입력 전 기준선이 없는 이전 기록입니다.');
  }
  final samples = trial.sensors;
  if (samples.isEmpty) throw const WeightedFeatureException('센서 기록이 없습니다.');
  final first = samples.map((s) => s.time).reduce(math.min);
  if (down - first < 0.55) {
    throw const WeightedFeatureException('입력 전 기준선이 550ms보다 짧습니다.');
  }
  final joined = joinSensors(samples, first, up).rows;
  if (joined.length < 8) throw const WeightedFeatureException('센서 행이 부족합니다.');
  final byTime = <double, List<List<double>>>{};
  for (final r in joined) {
    (byTime[r.time] ??= []).add([r.ax, r.ay, r.az, r.gx, r.gy, r.gz]);
  }
  final times = byTime.keys.toList()..sort();
  if (times.length < 8 || times.last <= times.first) {
    throw const WeightedFeatureException('센서 시각이 유효하지 않습니다.');
  }
  final values = [
    for (final t in times)
      [
        for (var c = 0; c < 6; c++)
          _mean([for (final row in byTime[t]!) row[c]]),
      ],
  ];
  final count = math.max(5, ((times.last - times.first) * 100).round() + 1);
  final timeline = [
    for (var i = 0; i < count; i++)
      times.first + (times.last - times.first) * i / (count - 1),
  ];
  final channels = [
    for (var c = 0; c < 6; c++)
      _interpolate(timeline, times, [for (final row in values) row[c]]),
  ];
  final idle = [
    for (var i = 0; i < count; i++)
      if (timeline[i] >= times.first + 0.2 && timeline[i] <= times.first + 0.5)
        i,
  ];
  if (idle.length < 5 || timeline[idle.last] >= down) {
    throw const WeightedFeatureException('입력 전 정지 기준선을 확보하지 못했습니다.');
  }
  final gravity = [
    for (var c = 0; c < 3; c++) _median([for (final i in idle) channels[c][i]]),
  ];
  final bias = [
    for (var c = 3; c < 6; c++) _median([for (final i in idle) channels[c][i]]),
  ];
  final z = _unit(gravity);
  final projectedX = _subtract([1, 0, 0], _scale(z, z[0]));
  final x = _norm(projectedX) < 1e-6
      ? _unit(_cross(_unit(_subtract([0, 1, 0], _scale(z, z[1]))), z))
      : _unit(projectedX);
  final y = _unit(_cross(z, x));
  final axes = [x, y, z];
  final aligned = List.generate(6, (_) => List<double>.filled(count, 0));
  for (var i = 0; i < count; i++) {
    for (var c = 0; c < 3; c++) {
      aligned[c][i] =
          _dot(axes[c], [for (var a = 0; a < 3; a++) channels[a][i]]);
      aligned[c + 3][i] = _dot(axes[c], [
        for (var a = 0; a < 3; a++) channels[a + 3][i] - bias[a],
      ]);
    }
  }
  final filtered = [
    for (final channel in aligned)
      _zeroPhase(channel, 20, [0.541196100146197, 1.306562964876377])
  ];
  final lowGravity = [
    for (var c = 0; c < 3; c++)
      _zeroPhase(filtered[c], 0.5, [1 / math.sqrt(2)]),
  ];
  final linear = [
    for (var c = 0; c < 3; c++)
      [
        for (var i = 0; i < count; i++) filtered[c][i] - lowGravity[c][i],
      ],
  ];
  final selected = [
    for (var i = 0; i < count; i++)
      if (timeline[i] >= down && timeline[i] <= up) i,
  ];
  if (selected.length < 5) {
    throw const WeightedFeatureException('터치 구간 센서 행이 부족합니다.');
  }
  final motion = [...linear, ...filtered.skip(3)];
  final features = <double>[];
  for (final channel in motion) {
    final v = [for (final i in selected) channel[i]];
    features.addAll([_mean(v), _std(v), v.last - v.first]);
  }
  for (var start = 0; start < 6; start += 3) {
    final mag = [
      for (final i in selected)
        math.sqrt(
            List.generate(3, (a) => motion[start + a][i] * motion[start + a][i])
                .reduce((a, b) => a + b)),
    ];
    features.addAll([_mean(mag), _std(mag)]);
  }
  features.add(up - down);
  if (features.length != weightedFeatures.length ||
      features.any((v) => !v.isFinite)) {
    throw const WeightedFeatureException('특징 계산 결과가 유효하지 않습니다.');
  }
  return features;
}

class WeightedClaimantModel {
  final List<double> scalerCenter, scalerScale, center, within, weight;
  final double threshold;
  const WeightedClaimantModel(this.scalerCenter, this.scalerScale, this.center,
      this.within, this.weight, this.threshold);

  double score(List<double> features) {
    if (features.length != weightedFeatures.length) {
      throw const WeightedFeatureException('특징 수가 다릅니다.');
    }
    var sum = 0.0;
    for (var c = 0; c < features.length; c++) {
      final z = (features[c] - scalerCenter[c]) / scalerScale[c];
      final d = weight[c] * (z - center[c]) / within[c];
      sum += d * d;
    }
    return -math.sqrt(sum / features.length);
  }

  Map<String, Object> toJson() => {
        'scalerCenter': scalerCenter,
        'scalerScale': scalerScale,
        'center': center,
        'within': within,
        'weight': weight,
        'threshold': threshold,
      };
  factory WeightedClaimantModel.fromJson(Map<String, dynamic> j) =>
      WeightedClaimantModel(
        _doubles(j['scalerCenter']),
        _doubles(j['scalerScale']),
        _doubles(j['center']),
        _doubles(j['within']),
        _doubles(j['weight']),
        (j['threshold'] as num).toDouble(),
      );
}

/// One user's 40 records fit their center and spread. The weights and
/// threshold come from the reference experiment.
WeightedClaimantModel fitWeightedClaimant(List<List<double>> samples) {
  if (samples.length != weightedEnrollmentCount ||
      samples.any((v) => v.length != weightedFeatures.length)) {
    throw ArgumentError('사용자 기록 $weightedEnrollmentCount개가 필요합니다.');
  }
  final train = samples;
  final center = [
    for (var c = 0; c < weightedFeatures.length; c++)
      _median([for (final row in train) row[c]])
  ];
  final scale = [
    for (var c = 0; c < weightedFeatures.length; c++)
      _iqr([for (final row in train) row[c]])
  ];
  final safeScale = [for (final s in scale) s == 0 ? 1.0 : s];
  final normalized = [
    for (final row in train)
      [
        for (var c = 0; c < weightedFeatures.length; c++)
          (row[c] - center[c]) / safeScale[c]
      ]
  ];
  final ownCenter = [
    for (var c = 0; c < weightedFeatures.length; c++)
      _median([for (final row in normalized) row[c]])
  ];
  final within = [
    for (var c = 0; c < weightedFeatures.length; c++)
      math.max(
          1.4826 *
              _median([
                for (final row in normalized) (row[c] - ownCenter[c]).abs()
              ]),
          0.25)
  ];
  return WeightedClaimantModel(center, safeScale, ownCenter, within,
      weightedReferenceWeights, weightedThreshold);
}

List<double> _doubles(Object? x) =>
    [for (final v in x as List) (v as num).toDouble()];
double _mean(List<double> v) => v.reduce((a, b) => a + b) / v.length;
double _std(List<double> v) {
  final m = _mean(v);
  return math.sqrt(_mean([for (final x in v) (x - m) * (x - m)]));
}

double _median(List<double> v) {
  final a = [...v]..sort();
  final n = a.length;
  return n.isOdd ? a[n ~/ 2] : (a[n ~/ 2 - 1] + a[n ~/ 2]) / 2;
}

double _iqr(List<double> v) => _percentile(v, .75) - _percentile(v, .25);
double _percentile(List<double> v, double p) {
  final a = [...v]..sort();
  final x = (a.length - 1) * p;
  final l = x.floor(), h = x.ceil();
  return a[l] + (a[h] - a[l]) * (x - l);
}

double _dot(List<double> a, List<double> b) =>
    List.generate(a.length, (i) => a[i] * b[i]).reduce((x, y) => x + y);
double _norm(List<double> a) => math.sqrt(_dot(a, a));
List<double> _unit(List<double> a) {
  final n = _norm(a);
  return n < 1e-9 ? [0, 0, 1] : [for (final x in a) x / n];
}

List<double> _scale(List<double> a, double f) => [for (final x in a) x * f];
List<double> _subtract(List<double> a, List<double> b) =>
    [for (var i = 0; i < a.length; i++) a[i] - b[i]];
List<double> _cross(List<double> a, List<double> b) => [
      a[1] * b[2] - a[2] * b[1],
      a[2] * b[0] - a[0] * b[2],
      a[0] * b[1] - a[1] * b[0]
    ];
List<double> _interpolate(
    List<double> target, List<double> times, List<double> values) {
  var j = 0;
  return [
    for (final t in target)
      () {
        while (j + 1 < times.length - 1 && times[j + 1] < t) {
          j++;
        }
        final span = times[j + 1] - times[j];
        return values[j] + (values[j + 1] - values[j]) * (t - times[j]) / span;
      }()
  ];
}

List<double> _zeroPhase(List<double> v, double cutoff, List<double> qs) {
  final pad = math.min(v.length - 2, 3 * (2 * qs.length + 1));
  if (pad < 1) return [...v];
  final extended = [
    for (var i = pad; i >= 1; i--) 2 * v.first - v[i],
    ...v,
    for (var i = v.length - 2; i >= v.length - pad - 1; i--) 2 * v.last - v[i]
  ];
  List<double> filter(List<double> input) {
    var result = input;
    for (final q in qs) {
      final k = math.tan(math.pi * cutoff / 100), k2 = k * k;
      final norm = 1 / (1 + k / q + k2);
      final b0 = k2 * norm, b1 = 2 * b0, b2 = b0;
      final a1 = 2 * (k2 - 1) * norm, a2 = (1 - k / q + k2) * norm;
      var z1 = result.first * (1 - b0), z2 = result.first * (b2 - a2);
      final output = <double>[];
      for (final x in result) {
        final y = b0 * x + z1;
        z1 = b1 * x - a1 * y + z2;
        z2 = b2 * x - a2 * y;
        output.add(y);
      }
      result = output;
    }
    return result;
  }

  final forward = filter(extended);
  final backward = filter(forward.reversed.toList()).reversed.toList();
  return backward.sublist(pad, pad + v.length);
}
