import 'dart:async';
import 'dart:math';
import 'package:flutter/services.dart';
import 'model.dart';

class CaptureApi {
  static const _method = MethodChannel('pattern_sensor/capture');
  static const _events = EventChannel('pattern_sensor/touch');
  Stream<Map<String, dynamic>> get touches => _events
      .receiveBroadcastStream()
      .map((e) => Map<String, dynamic>.from(e as Map));
  Future<Map<String, dynamic>> arm() async =>
      Map<String, dynamic>.from(await _method.invokeMethod<Map>('arm') ?? {});
  Future<Map<String, dynamic>> startFixed() async => Map<String, dynamic>.from(
      await _method.invokeMethod<Map>('startFixed') ?? {});
  Future<Map<String, dynamic>> finishFixed({bool force = false}) async =>
      Map<String, dynamic>.from(
          await _method.invokeMethod<Map>('finishFixed', {'force': force}) ??
              {});
  Future<Map<String, dynamic>> finish() async => Map<String, dynamic>.from(
      await _method.invokeMethod<Map>('finish') ?? {});
  /// Subscribes the IMU with a short rolling buffer. Completes once both
  /// accelerometer and gyroscope have produced a sample.
  Future<Map<String, dynamic>> armTouch() async => Map<String, dynamic>.from(
      await _method.invokeMethod<Map>('armTouch') ?? {});

  /// Stops the IMU and returns only samples inside [touch down, touch up].
  Future<Map<String, dynamic>> finishTouch() async =>
      Map<String, dynamic>.from(
          await _method.invokeMethod<Map>('finishTouch') ?? {});
  Future<void> cancel() async => _method.invokeMethod('cancel');
}

class PatternTracker {
  // Keep diagonal paths clear of adjacent nodes (minimum clearance: ~0.112).
  static const hitRadius = 0.08;

  /// When true, a touch that leaves the board area fails the attempt.
  final bool rejectOutsideBoard;
  PatternTracker({this.rejectOutsideBoard = false});
  final List<NodeVisit> visits = [];
  final List<TouchSample> touches = [];
  TouchSample? previous;
  String? error;
  double? start, end;

  void accept(Map<String, dynamic> event,
      {double? captureStart, double? captureEnd}) {
    final type = event['type'] as String;
    final t = (event['time'] as num).toDouble();
    final x = (event['x'] as num).toDouble();
    final y = (event['y'] as num).toDouble();
    final point = TouchSample(t, x, y, type);
    touches.add(point);
    if (rejectOutsideBoard && (x < 0 || x > 1 || y < 0 || y > 1)) {
      error ??= 'left_board';
    }
    if (type == 'DOWN' && captureStart != null && t < captureStart) {
      error ??= 'EARLY_TOUCH';
    }
    if (type == 'DOWN' && captureEnd != null && t >= captureEnd) {
      error ??= 'WINDOW_TIMEOUT';
    }
    if (type == 'UP' && captureEnd != null && t >= captureEnd) {
      error ??= 'WINDOW_TIMEOUT';
    }
    if (type == 'CANCEL' || type == 'MULTITOUCH') {
      error = type == 'MULTITOUCH' ? 'multitouch' : 'touch_cancelled';
      end ??= t;
      return;
    }
    if (type == 'DOWN') {
      if (start != null) {
        error = 'multiple_strokes';
        return;
      }
      start = t;
      final node = _nearest(x, y);
      if (node == null) {
        error = 'start_outside_node';
      } else {
        visits.add(NodeVisit(node, t, 'touch_detected', false, x: x, y: y));
      }
    } else if (type == 'MOVE' || type == 'UP') {
      if (end != null) {
        error ??= 'multiple_strokes';
        return;
      }
      if (previous != null) _crossings(previous!, point);
      if (type == 'UP') end = t;
    }
    previous = point;
  }

  int? _nearest(double x, double y) {
    for (var n = 1; n <= 9; n++) {
      final p = nodePoint(n);
      if (pow(x - p.$1, 2) + pow(y - p.$2, 2) <= hitRadius * hitRadius) {
        return n;
      }
    }
    return null;
  }

  void _crossings(TouchSample a, TouchSample b) {
    if (b.time < a.time) {
      error ??= 'touch_time_order';
    }
    final dx = b.x - a.x, dy = b.y - a.y, len2 = dx * dx + dy * dy;
    if (len2 == 0) return;
    final hits = <(double, int)>[];
    for (var n = 1; n <= 9; n++) {
      if (visits.any((v) => v.node == n)) continue;
      final p = nodePoint(n), ox = a.x - p.$1, oy = a.y - p.$2;
      final A = len2,
          B = 2 * (ox * dx + oy * dy),
          C = ox * ox + oy * oy - hitRadius * hitRadius;
      final disc = B * B - 4 * A * C;
      if (disc < 0) continue;
      final entry = (-B - sqrt(disc)) / (2 * A);
      if (entry >= 0 && entry <= 1) hits.add((entry, n));
    }
    hits.sort((a, b) => a.$1.compareTo(b.$1));
    for (final hit in hits) {
      if (visits.any((v) => v.node == hit.$2)) continue;
      final wanted =
          PatternRules.normalize([...visits.map((v) => v.node), hit.$2]);
      for (final n in wanted.skip(visits.length)) {
        var fraction = hit.$1;
        var source = 'touch_detected';
        var estimated = true; // segment/radius entry is interpolated
        if (n != hit.$2) {
          final p = nodePoint(n);
          fraction = ((p.$1 - a.x) * dx + (p.$2 - a.y) * dy) / len2;
          final cx = a.x + dx * fraction, cy = a.y + dy * fraction;
          if (fraction < 0 ||
              fraction > 1 ||
              sqrt(pow(cx - p.$1, 2) + pow(cy - p.$2, 2)) > hitRadius) {
            error = 'midpoint_time_unverified';
            return;
          }
          source = 'midpoint_auto';
        }
        final time = a.time + (b.time - a.time) * fraction;
        if (visits.isNotEmpty && time <= visits.last.time) {
          error ??= 'node_time_order';
        }
        visits.add(NodeVisit(n, time, source, estimated,
            x: a.x + dx * fraction, y: a.y + dy * fraction));
      }
    }
  }
}

(double, double) nodePoint(int n) =>
    (((n - 1) % 3 + 1) / 4, ((n - 1) ~/ 3 + 1) / 4);
