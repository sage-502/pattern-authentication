import 'dart:math';

class PatternRules {
  static List<int> normalize(Iterable<int> requested) {
    final result = <int>[];
    for (final node in requested) {
      if (node < 1 || node > 9 || result.contains(node)) continue;
      if (result.isNotEmpty) {
        final a = result.last - 1, b = node - 1;
        final dr = b ~/ 3 - a ~/ 3, dc = b % 3 - a % 3;
        final steps = dr.abs().gcd(dc.abs());
        for (var i = 1; i < steps; i++) {
          final middle =
              (a ~/ 3 + dr ~/ steps * i) * 3 + (a % 3 + dc ~/ steps * i) + 1;
          if (!result.contains(middle)) result.add(middle);
        }
      }
      result.add(node);
    }
    return result;
  }
}

class NodeVisit {
  final int node;
  final double time;
  final String source;
  final bool estimated;
  final double? x, y;
  const NodeVisit(this.node, this.time, this.source, this.estimated,
      {this.x, this.y});
  Map<String, dynamic> toJson() => {
        'node': node,
        'time': time,
        'source': source,
        'estimated': estimated,
        'x': x,
        'y': y
      };
  factory NodeVisit.fromJson(Map<String, dynamic> j) => NodeVisit(
      j['node'] as int,
      (j['time'] as num).toDouble(),
      j['source'] as String,
      j['estimated'] as bool,
      x: (j['x'] as num?)?.toDouble(),
      y: (j['y'] as num?)?.toDouble());
}

class TouchSample {
  final double time, x, y;
  final String type;
  const TouchSample(this.time, this.x, this.y, this.type);
  Map<String, dynamic> toJson() => {'time': time, 'x': x, 'y': y, 'type': type};
  factory TouchSample.fromJson(Map<String, dynamic> j) => TouchSample(
      (j['time'] as num).toDouble(),
      (j['x'] as num).toDouble(),
      (j['y'] as num).toDouble(),
      j['type'] as String);
}

class SensorSample {
  final double time, x, y, z;
  final String type;
  final num? nativeTimestamp;
  final String timebase;
  const SensorSample(this.time, this.x, this.y, this.z, this.type,
      {this.nativeTimestamp, this.timebase = 'common_monotonic_seconds'});
  Map<String, dynamic> toJson() => {
        'time': time,
        'x': x,
        'y': y,
        'z': z,
        'type': type,
        'nativeTimestamp': nativeTimestamp,
        'timebase': timebase
      };
  factory SensorSample.fromJson(Map<String, dynamic> j) => SensorSample(
      (j['time'] as num).toDouble(),
      (j['x'] as num).toDouble(),
      (j['y'] as num).toDouble(),
      (j['z'] as num).toDouble(),
      j['type'] as String,
      nativeTimestamp: j['nativeTimestamp'] as num?,
      timebase: j['timebase'] as String? ?? 'common_monotonic_seconds');
}

class TrialRecord {
  static const fixedWindowMode = 'fixed_window_v1';
  static const fixedWindow5Mode = 'fixed_window_5s_v1';
  static const legacyMode = 'legacy_touch_cropped';

  /// v3: the trial starts at the first pointer down on the board and ends at
  /// the pointer up of the same gesture. Only sensor samples inside
  /// [actualTouchDown, actualTouchUp] are stored.
  static const touchBoundedMode = 'touch_bounded_v1';
  static const touchCalibratedMode = 'touch_calibrated_v2';
  static const enrollmentSource = 'ENROLLMENT';

  /// Successful login captures stored as training data (below 40 valid).
  static const loginSource = 'LOGIN';
  final String id,
      sessionId,
      participantId,
      deviceId,
      hand,
      posture,
      holdingHand;
  final List<int> target;
  final List<NodeVisit> visits;
  final List<TouchSample> touches;
  final List<SensorSample> sensors;
  final double start, end, clockErrorMs;
  final int index;
  final String platform, model, osVersion;
  final String targetDisplayName;
  final String? captureError;
  final String captureMode;
  final double? buttonT0Monotonic, captureStartMonotonic, captureEndMonotonic;
  final double? actualTouchDown, actualTouchUp;
  final bool windowComplete;
  final String? windowError;
  final double buttonDispatchDelayMs, deadlineErrorMs;
  final double hitRadiusNorm;
  final String? source;
  final String? sensorTimestampBasis;
  const TrialRecord(
      {required this.id,
      required this.sessionId,
      required this.participantId,
      required this.deviceId,
      required this.hand,
      required this.posture,
      required this.holdingHand,
      required this.target,
      required this.visits,
      required this.touches,
      required this.sensors,
      required this.start,
      required this.end,
      required this.clockErrorMs,
      required this.index,
      required this.platform,
      required this.model,
      required this.osVersion,
      this.targetDisplayName = '',
      this.captureError,
      this.captureMode = legacyMode,
      this.buttonT0Monotonic,
      this.captureStartMonotonic,
      this.captureEndMonotonic,
      this.actualTouchDown,
      this.actualTouchUp,
      this.windowComplete = false,
      this.windowError,
      this.buttonDispatchDelayMs = 0,
      this.deadlineErrorMs = 0,
      this.hitRadiusNorm = 0.12,
      this.source,
      this.sensorTimestampBasis});
  List<int> get actual => visits.map((v) => v.node).toList();
  bool get matched => actual.join('-') == target.join('-');
  Map<String, dynamic> toJson() => {
        'id': id,
        'sessionId': sessionId,
        'participantId': participantId,
        'deviceId': deviceId,
        'hand': hand,
        'posture': posture,
        'holdingHand': holdingHand,
        'target': target,
        'visits': visits.map((v) => v.toJson()).toList(),
        'touches': touches.map((v) => v.toJson()).toList(),
        'sensors': sensors.map((v) => v.toJson()).toList(),
        'start': start,
        'end': end,
        'clockErrorMs': clockErrorMs,
        'index': index,
        'platform': platform,
        'model': model,
        'osVersion': osVersion,
        'captureError': captureError,
        'targetDisplayName': targetDisplayName,
        'capture_mode': captureMode,
        'button_t0_monotonic': buttonT0Monotonic,
        'capture_start_monotonic': captureStartMonotonic,
        'capture_end_monotonic': captureEndMonotonic,
        'actual_touch_down': actualTouchDown,
        'actual_touch_up': actualTouchUp,
        'window_duration_sec': captureMode == fixedWindow5Mode
            ? 5.0
            : captureMode == fixedWindowMode
                ? 4.0
                : null,
        'pre_delay_sec': captureMode == fixedWindow5Mode
            ? 0.0
            : captureMode == fixedWindowMode
                ? 0.5
                : null,
        'window_completeness': windowComplete,
        'window_error': windowError,
        'button_dispatch_delay_ms': buttonDispatchDelayMs,
        'deadline_error_ms': deadlineErrorMs,
        'hit_radius_norm': hitRadiusNorm,
        if (source != null) 'source': source,
        if (sensorTimestampBasis != null)
          'sensor_timestamp_basis': sensorTimestampBasis,
      };
  factory TrialRecord.fromJson(Map<String, dynamic> j) => TrialRecord(
      id: j['id'],
      sessionId: j['sessionId'],
      participantId: j['participantId'],
      deviceId: j['deviceId'],
      hand: j['hand'],
      posture: j['posture'],
      holdingHand: j['holdingHand'],
      target: (j['target'] as List).cast<int>(),
      visits: (j['visits'] as List)
          .map((e) => NodeVisit.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      touches: (j['touches'] as List)
          .map((e) => TouchSample.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      sensors: (j['sensors'] as List)
          .map((e) => SensorSample.fromJson(Map<String, dynamic>.from(e)))
          .toList(),
      start: (j['start'] as num).toDouble(),
      end: (j['end'] as num).toDouble(),
      clockErrorMs: (j['clockErrorMs'] as num).toDouble(),
      index: j['index'],
      platform: j['platform'],
      model: j['model'],
      osVersion: j['osVersion'],
      captureError: j['captureError'],
      targetDisplayName: j['targetDisplayName'] ?? '',
      captureMode: j['capture_mode'] ?? legacyMode,
      buttonT0Monotonic: (j['button_t0_monotonic'] as num?)?.toDouble(),
      captureStartMonotonic: (j['capture_start_monotonic'] as num?)?.toDouble(),
      captureEndMonotonic: (j['capture_end_monotonic'] as num?)?.toDouble(),
      actualTouchDown: (j['actual_touch_down'] as num?)?.toDouble(),
      actualTouchUp: (j['actual_touch_up'] as num?)?.toDouble(),
      windowComplete: j['window_completeness'] == true,
      windowError: j['window_error'] as String?,
      buttonDispatchDelayMs:
          (j['button_dispatch_delay_ms'] as num?)?.toDouble() ?? 0,
      deadlineErrorMs: (j['deadline_error_ms'] as num?)?.toDouble() ?? 0,
      hitRadiusNorm: (j['hit_radius_norm'] as num?)?.toDouble() ?? 0.12,
      source: j['source'] as String?,
      sensorTimestampBasis: j['sensor_timestamp_basis'] as String?);
}

class JoinedRow {
  final double time, ax, ay, az, gx, gy, gz;
  const JoinedRow(
      this.time, this.ax, this.ay, this.az, this.gx, this.gy, this.gz);
}

class JoinResult {
  final List<JoinedRow> rows;
  final int missing;
  final double largestAgeMs;
  const JoinResult(this.rows, this.missing, this.largestAgeMs);
}

JoinResult joinSensors(List<SensorSample> samples, double start, double end,
    {double maxAge = 0.05,
    bool endExclusive = false,
    bool includeWarmup = false}) {
  final ordered = samples
      .asMap()
      .entries
      .where((e) =>
          (includeWarmup || e.value.time >= start) &&
          (endExclusive ? e.value.time < end : e.value.time <= end))
      .toList()
    ..sort((a, b) {
      final c = a.value.time.compareTo(b.value.time);
      return c != 0 ? c : a.key.compareTo(b.key);
    });
  SensorSample? accel, gyro;
  final rows = <JoinedRow>[];
  var missing = 0;
  var maxGap = 0.0;
  for (final entry in ordered) {
    final sample = entry.value;
    final inWindow = sample.time >= start;
    if (![sample.time, sample.x, sample.y, sample.z].every((v) => v.isFinite)) {
      if (inWindow) missing++;
      continue;
    }
    if (sample.type == 'ACCEL') accel = sample;
    if (sample.type == 'GYRO') gyro = sample;
    final a = accel, g = gyro;
    if (!inWindow) continue;
    if (a == null || g == null) {
      missing++;
      continue;
    }
    final gap = max(sample.time - a.time, sample.time - g.time);
    maxGap = max(maxGap, gap);
    if (gap > maxAge) {
      missing++;
      continue;
    }
    rows.add(JoinedRow(sample.time, a.x, a.y, a.z, g.x, g.y, g.z));
  }
  return JoinResult(rows, missing, maxGap * 1000);
}

class TrialQuality {
  final bool eligible;
  final String reason;
  final String result;
  final JoinResult joined;
  const TrialQuality(this.eligible, this.reason, this.result, this.joined);
}

TrialQuality assess(TrialRecord t) {
  if (t.captureMode == TrialRecord.touchBoundedMode ||
      t.captureMode == TrialRecord.touchCalibratedMode) {
    return _assessTouch(t);
  }
  final fiveSeconds = t.captureMode == TrialRecord.fixedWindow5Mode;
  final fixed = fiveSeconds || t.captureMode == TrialRecord.fixedWindowMode;
  final windowStart = t.captureStartMonotonic;
  final windowEnd = t.captureEndMonotonic;
  final joined = fixed && windowStart != null && windowEnd != null
      ? joinSensors(t.sensors, windowStart, windowEnd,
          endExclusive: true, includeWarmup: true)
      : fixed
          ? const JoinResult([], 0, 0)
          : joinSensors(t.sensors, t.start, t.end);
  final actual = t.actual;
  var reason = '';
  if (t.captureError != null) {
    reason = t.captureError!;
  } else if (fixed &&
      (windowStart == null ||
          windowEnd == null ||
          t.buttonT0Monotonic == null ||
          (windowStart - t.buttonT0Monotonic! - (fiveSeconds ? 0.0 : 0.5))
                  .abs() >
              0.000001 ||
          (windowEnd - windowStart - (fiveSeconds ? 5.0 : 4.0)).abs() >
              0.000001)) {
    reason = 'WINDOW_METADATA_INVALID';
  } else if (fixed && !t.windowComplete) {
    reason = t.windowError ?? 'WINDOW_INCOMPLETE';
  } else if (fixed && t.windowError != null) {
    reason = t.windowError!;
  } else if (fixed && t.buttonDispatchDelayMs > 100) {
    reason = 'BUTTON_DISPATCH_DELAY';
  } else if (fixed && t.deadlineErrorMs > 100) {
    reason = 'WINDOW_DEADLINE_DELAY';
  } else if (fixed && t.actualTouchDown == null) {
    reason = 'NO_INPUT_IN_WINDOW';
  } else if (fixed &&
      t.actualTouchDown! < windowStart! + (fiveSeconds ? 0.5 : 0.0)) {
    reason = 'EARLY_TOUCH';
  } else if (fixed &&
      (t.actualTouchUp == null || t.actualTouchUp! >= windowEnd!)) {
    reason = 'WINDOW_TIMEOUT';
  } else if (fixed &&
      !fiveSeconds &&
      !_sensorsReadyAtStart(t.sensors, windowStart!)) {
    reason = 'SENSOR_NOT_READY_IN_WINDOW';
  } else if (fiveSeconds && !_sensorsReadySoon(t.sensors, windowStart!)) {
    reason = 'SENSOR_NOT_READY_IN_WINDOW';
  } else if (t.end <= t.start ||
      t.visits.isEmpty ||
      t.visits.first.time != t.start) {
    reason = 'incomplete_stroke';
  } else if (actual.length < (fiveSeconds ? 3 : 4) ||
      actual.length > 9 ||
      actual.toSet().length != actual.length) {
    reason = 'invalid_pattern';
  } else if (t.visits.any((v) => v.time < t.start || v.time > t.end) ||
      List.generate(max(0, t.visits.length - 1),
          (i) => t.visits[i + 1].time <= t.visits[i].time).contains(true)) {
    reason = 'node_time_order';
  } else if (t.clockErrorMs > 5) {
    reason = 'clock_offset_error';
  } else if (t.visits.any((v) => v.source == 'midpoint_auto' && !v.estimated)) {
    reason = 'midpoint_time_unverified';
  } else if (joined.rows.isEmpty ||
      joined.rows.length / (joined.rows.length + joined.missing) < 0.95) {
    reason = 'sensor_coverage';
  } else if (fixed &&
      !_windowRowsContinuous(joined.rows, windowStart!, windowEnd!)) {
    reason = 'WINDOW_SENSOR_GAP';
  } else {
    for (var i = 0; i < t.visits.length - 1; i++) {
      if (joined.rows
              .where((r) =>
                  r.time >= t.visits[i].time && r.time <= t.visits[i + 1].time)
              .length <
          3) {
        reason = 'segment_sensor_count';
        break;
      }
    }
  }
  final validInput = actual.length >= (fiveSeconds ? 3 : 4) &&
      actual.length <= 9 &&
      actual.toSet().length == actual.length &&
      t.end > t.start &&
      t.visits.isNotEmpty &&
      t.visits.first.time == t.start &&
      !t.visits.any((v) => v.time < t.start || v.time > t.end) &&
      !List.generate(max(0, t.visits.length - 1),
          (i) => t.visits[i + 1].time <= t.visits[i].time).contains(true);
  final fixedInputError = fixed &&
      (t.actualTouchDown == null ||
          (windowStart != null &&
              t.actualTouchDown! < windowStart + (fiveSeconds ? 0.5 : 0.0)) ||
          t.actualTouchUp == null ||
          (windowEnd != null && t.actualTouchUp! >= windowEnd));
  final result = t.captureError != null || fixedInputError
      ? 'capture_error'
      : t.end <= t.start
          ? 'incomplete'
          : !validInput
              ? 'invalid'
              : t.matched
                  ? 'matched'
                  : 'mismatched';
  return TrialQuality(reason.isEmpty, reason, result, joined);
}

bool _sensorsReadyAtStart(List<SensorSample> samples, double start) {
  bool recent(String type) => samples.any((s) =>
      s.type == type &&
      s.time <= start &&
      s.time >= start - 0.05 &&
      [s.x, s.y, s.z].every((v) => v.isFinite));
  return recent('ACCEL') && recent('GYRO');
}

bool _sensorsReadySoon(List<SensorSample> samples, double start) {
  bool recent(String type) => samples.any((s) =>
      s.type == type &&
      s.time >= start &&
      s.time <= start + 0.1 &&
      [s.x, s.y, s.z].every((v) => v.isFinite));
  return recent('ACCEL') && recent('GYRO');
}

bool _windowRowsContinuous(List<JoinedRow> rows, double start, double end) {
  if (rows.isEmpty ||
      rows.first.time > start + 0.1 ||
      rows.last.time < end - 0.1) {
    return false;
  }
  for (var i = 1; i < rows.length; i++) {
    if (rows[i].time - rows[i - 1].time > 0.1) return false;
  }
  return true;
}

/// Quality rules for [TrialRecord.touchBoundedMode].
///
/// The v1 capture contains only the touch interval. Calibrated v2 captures
/// may also contain up to one second before touch for the idle baseline.
TrialQuality _assessTouch(TrialRecord t) {
  final down = t.actualTouchDown, up = t.actualTouchUp;
  final joined = down != null && up != null && up > down
      ? joinSensors(t.sensors, down, up)
      : const JoinResult([], 0, 0);
  final actual = t.actual;
  final validInput = actual.length >= 3 &&
      actual.length <= 9 &&
      actual.toSet().length == actual.length &&
      t.end > t.start &&
      t.visits.isNotEmpty &&
      t.visits.first.time == t.start &&
      !t.visits.any((v) => v.time < t.start || v.time > t.end) &&
      !List.generate(max(0, t.visits.length - 1),
          (i) => t.visits[i + 1].time <= t.visits[i].time).contains(true);
  var reason = '';
  if (t.captureError != null) {
    reason = t.captureError!;
  } else if (down == null || up == null) {
    reason = 'TOUCH_BOUNDARY_MISSING';
  } else if (up <= down || t.start != down || t.end != up) {
    reason = 'TOUCH_BOUNDARY_INVALID';
  } else if (t.sensors.any((s) =>
      s.time > up ||
      (t.captureMode == TrialRecord.touchBoundedMode && s.time < down) ||
      (t.captureMode == TrialRecord.touchCalibratedMode &&
          s.time < down - 1.0))) {
    reason = 'SENSOR_OUTSIDE_TOUCH_WINDOW';
  } else if (!validInput) {
    reason = actual.length < 3 ||
            actual.length > 9 ||
            actual.toSet().length != actual.length
        ? 'invalid_pattern'
        : 'node_time_order';
  } else if (t.clockErrorMs > 5) {
    reason = 'clock_offset_error';
  } else if (t.visits.any((v) => v.source == 'midpoint_auto' && !v.estimated)) {
    reason = 'midpoint_time_unverified';
  } else if (joined.rows.isEmpty ||
      joined.rows.length / (joined.rows.length + joined.missing) < 0.95) {
    reason = 'sensor_coverage';
  } else if (!_windowRowsContinuous(joined.rows, down, up)) {
    reason = 'TOUCH_WINDOW_SENSOR_GAP';
  } else {
    for (var i = 0; i < t.visits.length - 1; i++) {
      if (joined.rows
              .where((r) =>
                  r.time >= t.visits[i].time && r.time <= t.visits[i + 1].time)
              .length <
          3) {
        reason = 'segment_sensor_count';
        break;
      }
    }
  }
  final result = t.captureError != null || down == null || up == null
      ? 'capture_error'
      : t.end <= t.start
          ? 'incomplete'
          : !validInput
              ? 'invalid'
              : t.matched
                  ? 'matched'
                  : 'mismatched';
  return TrialQuality(reason.isEmpty, reason, result, joined);
}
