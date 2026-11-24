import 'dart:math' as math;

import 'behavior_auth_params.dart';
import 'model.dart';

/// Legacy touch-window feature representation retained while selecting usable
/// enrollment samples. Two one-class matchers are represented:
///
///  1. Motion shape: raw 6-axis rows in [touch down, touch up] → duplicates
///     averaged → [behaviorSeqLen] points over the window → per-channel
///     standardisation ([behaviorSeqMean]/[behaviorSeqStd]) → multichannel
///     DTW (Sakoe-Chiba band [behaviorDtwBand]). Score = −mean of the
///     [behaviorDtwK] smallest distances to the enrolled sequences.
///  2. Touch timing: node-to-node intervals, the same as fractions, touch
///     down → first node, last node → touch up, total. Scaler/template from
///     the user's own trials. Score = −mean(|z − mean| / (MAD + floor)).
///
/// Each matcher score is standardised by the median/MAD of its
/// leave-one-out scores on the training trials; the fused score is their
/// mean. Accept when fused score ≥ threshold.
///
/// The current v4.2 login decision is implemented in
/// `claimant_weighted_auth.dart`. This is not a validated security mechanism.

/// One joined sample: timestamp (s) and ax, ay, az, gx, gy, gz.
typedef SensorRow = List<double>;

class BehaviorFeatureException implements Exception {
  final String message;
  const BehaviorFeatureException(this.message);
  @override
  String toString() => message;
}

/// Joined rows of a stored trial limited to its touch window.
List<SensorRow> touchRowsFromTrial(TrialRecord trial) {
  final down = trial.actualTouchDown ?? trial.start;
  final up = trial.actualTouchUp ?? trial.end;
  return [
    for (final r in joinSensors(trial.sensors, down, up).rows)
      [r.time, r.ax, r.ay, r.az, r.gx, r.gy, r.gz],
  ];
}

/// One attempt prepared for matching.
class BehaviorSample {
  /// [behaviorSeqLen] × 6 standardised motion sequence.
  final List<List<double>> sequence;
  final List<double> timing;
  const BehaviorSample(this.sequence, this.timing);

  factory BehaviorSample.fromRows(
      List<SensorRow> rows, List<double> nodeTimes, double down, double up) {
    final window = [
      for (final r in rows)
        if (r[0] >= down && r[0] <= up) r,
    ];
    final raw = rawSequence(window);
    final sequence = [
      for (final p in raw)
        [for (var c = 0; c < 6; c++) (p[c] - behaviorSeqMean[c]) / behaviorSeqStd[c]],
    ];
    return BehaviorSample(sequence, timingFeatures(nodeTimes, down, up));
  }

  factory BehaviorSample.fromTrial(TrialRecord trial) => BehaviorSample.fromRows(
      touchRowsFromTrial(trial),
      [for (final v in trial.visits) v.time],
      trial.actualTouchDown ?? trial.start,
      trial.actualTouchUp ?? trial.end);
}

/// Time-normalised raw sequence (before standardisation).
List<List<double>> rawSequence(List<SensorRow> rows) {
  final sorted = List<SensorRow>.of(rows)..sort((a, b) => a[0].compareTo(b[0]));
  final times = <double>[];
  final sums = <List<double>>[];
  final counts = <int>[];
  for (final r in sorted) {
    if (times.isNotEmpty && times.last == r[0]) {
      for (var i = 0; i < 6; i++) {
        sums.last[i] += r[i + 1];
      }
      counts[counts.length - 1]++;
    } else {
      times.add(r[0]);
      sums.add([for (var i = 1; i <= 6; i++) r[i]]);
      counts.add(1);
    }
  }
  if (times.length < behaviorMinRows || !(times.last > times.first)) {
    throw const BehaviorFeatureException('Too few sensor events during touch');
  }
  final span = times.last - times.first;
  final tt = [for (final t in times) (t - times.first) / span];
  final grid = [
    for (var k = 0; k < behaviorSeqLen; k++) k / (behaviorSeqLen - 1),
  ];
  final channels = [
    for (var c = 0; c < 6; c++)
      _interp(grid, tt, [for (var k = 0; k < times.length; k++) sums[k][c] / counts[k]]),
  ];
  return [
    for (var k = 0; k < behaviorSeqLen; k++) [for (var c = 0; c < 6; c++) channels[c][k]],
  ];
}

List<double> timingFeatures(List<double> nodes, double down, double up) {
  if (nodes.length < 2) {
    throw const BehaviorFeatureException('A pattern needs at least 2 node times');
  }
  final iv = [for (var i = 1; i < nodes.length; i++) nodes[i] - nodes[i - 1]];
  final total = iv.fold(0.0, (a, b) => a + b);
  if (!(total > 0)) throw const BehaviorFeatureException('Invalid node times');
  return [
    ...iv,
    for (final v in iv) v / total,
    nodes.first - down,
    up - nodes.last,
    up - down,
  ];
}

/// Multichannel DTW with a Sakoe-Chiba band (same recurrence as Python).
double dtwDistance(List<List<double>> a, List<List<double>> b,
    {int band = behaviorDtwBand}) {
  final n = a.length;
  var prev = List<double>.filled(n + 1, double.infinity);
  prev[0] = 0;
  for (var i = 1; i <= n; i++) {
    final cur = List<double>.filled(n + 1, double.infinity);
    final lo = math.max(1, i - band), hi = math.min(n, i + band);
    for (var j = lo; j <= hi; j++) {
      var s = 0.0;
      for (var c = 0; c < a[i - 1].length; c++) {
        final d = a[i - 1][c] - b[j - 1][c];
        s += d * d;
      }
      final best = math.min(math.min(prev[j - 1], prev[j]), cur[j - 1]);
      cur[j] = math.sqrt(s) + best;
    }
    prev = cur;
  }
  return prev[n];
}

double _meanOfSmallest(List<double> d) {
  final s = List<double>.of(d)..sort();
  final k = math.min(behaviorDtwK, s.length);
  return s.take(k).fold(0.0, (a, b) => a + b) / k;
}

class TimingTemplate {
  final List<double> center, scale, mean, dev;
  const TimingTemplate(this.center, this.scale, this.mean, this.dev);

  factory TimingTemplate.fit(List<List<double>> m) {
    final dims = m.first.length;
    final center = <double>[], scale = <double>[];
    for (var d = 0; d < dims; d++) {
      final col = [for (final r in m) r[d]];
      center.add(_median(col));
      final s = _percentile(col, 75) - _percentile(col, 25);
      scale.add(s == 0 ? 1.0 : s);
    }
    final z = [
      for (final r in m) [for (var d = 0; d < dims; d++) (r[d] - center[d]) / scale[d]],
    ];
    final mean = [for (var d = 0; d < dims; d++) _mean([for (final r in z) r[d]])];
    final dev = [
      for (var d = 0; d < dims; d++)
        _mean([for (final r in z) (r[d] - mean[d]).abs()]) + behaviorTimingFloor,
    ];
    return TimingTemplate(center, scale, mean, dev);
  }

  double score(List<double> x) {
    if (x.length != center.length) {
      throw const BehaviorFeatureException('Pattern length differs from the model');
    }
    var s = 0.0;
    for (var d = 0; d < center.length; d++) {
      s += ((x[d] - center[d]) / scale[d] - mean[d]).abs() / dev[d];
    }
    return -s / center.length;
  }

  Map<String, dynamic> toJson() =>
      {'center': center, 'scale': scale, 'mean': mean, 'dev': dev};
  factory TimingTemplate.fromJson(Map<String, dynamic> j) => TimingTemplate(
      _doubles(j['center']), _doubles(j['scale']), _doubles(j['mean']), _doubles(j['dev']));
}

class BehaviorModel {
  final List<List<List<double>>> sequences;
  final TimingTemplate timing;

  /// (median, MAD·1.4826) of the leave-one-out matcher scores.
  final (double, double) dtwNorm, timingNorm;
  const BehaviorModel(this.sequences, this.timing, this.dtwNorm, this.timingNorm);

  /// Template from >= 3 training samples of one pattern.
  factory BehaviorModel.fit(List<BehaviorSample> samples) {
    final n = samples.length;
    if (n < 3) throw ArgumentError('At least 3 training trials are needed');
    final dims = samples.first.timing.length;
    if (samples.any((s) => s.timing.length != dims)) {
      throw ArgumentError('Training trials have different pattern lengths');
    }
    final dist = List.generate(n, (_) => List<double>.filled(n, 0));
    for (var i = 0; i < n; i++) {
      for (var j = i + 1; j < n; j++) {
        dist[i][j] = dist[j][i] = dtwDistance(samples[i].sequence, samples[j].sequence);
      }
    }
    final looDtw = <double>[], looTiming = <double>[];
    for (var i = 0; i < n; i++) {
      looDtw.add(-_meanOfSmallest([
        for (var j = 0; j < n; j++)
          if (j != i) dist[i][j],
      ]));
      final rest = [
        for (var j = 0; j < n; j++)
          if (j != i) samples[j].timing,
      ];
      looTiming.add(TimingTemplate.fit(rest).score(samples[i].timing));
    }
    return BehaviorModel(
      [for (final s in samples) s.sequence],
      TimingTemplate.fit([for (final s in samples) s.timing]),
      _robust(looDtw),
      _robust(looTiming),
    );
  }

  double score(BehaviorSample sample) {
    final sDtw = -_meanOfSmallest(
        [for (final e in sequences) dtwDistance(sample.sequence, e)]);
    final sTiming = timing.score(sample.timing);
    return 0.5 *
        ((sDtw - dtwNorm.$1) / dtwNorm.$2 + (sTiming - timingNorm.$1) / timingNorm.$2);
  }

  Map<String, dynamic> toJson() => {
        'sequences': sequences,
        'timing': timing.toJson(),
        'dtwNorm': [dtwNorm.$1, dtwNorm.$2],
        'timingNorm': [timingNorm.$1, timingNorm.$2],
      };

  factory BehaviorModel.fromJson(Map<String, dynamic> j) {
    final dn = _doubles(j['dtwNorm']), tn = _doubles(j['timingNorm']);
    return BehaviorModel(
      [
        for (final s in j['sequences'] as List)
          [for (final p in s as List) _doubles(p)],
      ],
      TimingTemplate.fromJson((j['timing'] as Map).cast<String, dynamic>()),
      (dn[0], dn[1]),
      (tn[0], tn[1]),
    );
  }
}

bool isBehaviorAccepted(double score, {double threshold = behaviorThreshold}) =>
    score >= threshold;

// ---------------------------------------------------------------- numerics

List<double> _doubles(Object? v) =>
    [for (final x in v as List) (x as num).toDouble()];

(double, double) _robust(List<double> v) {
  final med = _median(v);
  final mad = _median([for (final x in v) (x - med).abs()]) * behaviorMadToSigma;
  return (med, math.max(mad, 1e-6));
}

List<double> _interp(List<double> x, List<double> xp, List<double> fp) {
  final out = <double>[];
  var j = 0;
  for (final v in x) {
    if (v <= xp.first) {
      out.add(fp.first);
      continue;
    }
    if (v >= xp.last) {
      out.add(fp.last);
      continue;
    }
    while (j < xp.length - 2 && xp[j + 1] < v) {
      j++;
    }
    while (j > 0 && xp[j] > v) {
      j--;
    }
    final t = (v - xp[j]) / (xp[j + 1] - xp[j]);
    out.add(fp[j] + t * (fp[j + 1] - fp[j]));
  }
  return out;
}

double _mean(List<double> v) => v.fold(0.0, (a, b) => a + b) / v.length;

double _median(List<double> values) {
  final s = List<double>.of(values)..sort();
  final mid = s.length ~/ 2;
  return s.length.isOdd ? s[mid] : (s[mid - 1] + s[mid]) / 2;
}

/// numpy.percentile default (linear interpolation).
double _percentile(List<double> values, double q) {
  final s = List<double>.of(values)..sort();
  final pos = q / 100 * (s.length - 1);
  final lo = pos.floor(), hi = pos.ceil();
  return s[lo] + (s[hi] - s[lo]) * (pos - lo);
}
