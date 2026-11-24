import 'package:flutter_test/flutter_test.dart';
import 'package:pattern_sensor_collector/model.dart';
import 'package:pattern_sensor_collector/capture.dart';

void main() {
  test('Android middle nodes are inserted once, in order', () {
    expect(PatternRules.normalize([1, 3, 7]), [1, 2, 3, 5, 7]);
    expect(PatternRules.normalize([1, 2, 3, 1]), [1, 2, 3]);
    expect(PatternRules.normalize([1, 9]), [1, 5, 9]);
  });
  test('touch segment records a single stroke and normalized middle nodes', () {
    final tracker = PatternTracker();
    tracker.accept({'type': 'DOWN', 'time': 100.0, 'x': 0.25, 'y': 0.25});
    tracker.accept({'type': 'MOVE', 'time': 100.3, 'x': 0.75, 'y': 0.25});
    tracker.accept({'type': 'UP', 'time': 100.4, 'x': 0.75, 'y': 0.25});
    expect(tracker.visits.map((v) => v.node), [1, 2, 3]);
    expect(tracker.visits.first.time, 100.0);
    expect(tracker.visits.skip(1).every((v) => v.estimated), true);
    expect(tracker.touches.length, 3);
  });
  test('long diagonal 1 to 6 does not collect nearby 2 or 5', () {
    final tracker = PatternTracker();
    tracker.accept({'type': 'DOWN', 'time': 100.0, 'x': 0.25, 'y': 0.25});
    tracker.accept({'type': 'UP', 'time': 100.4, 'x': 0.75, 'y': 0.5});
    expect(tracker.visits.map((v) => v.node), [1, 6]);
    expect(tracker.error, isNull);
  });
  test('long diagonal 2 to 7 does not collect nearby 5 or 4', () {
    final tracker = PatternTracker();
    tracker.accept({'type': 'DOWN', 'time': 100.0, 'x': 0.5, 'y': 0.25});
    tracker.accept({'type': 'UP', 'time': 100.4, 'x': 0.25, 'y': 0.75});
    expect(tracker.visits.map((v) => v.node), [2, 7]);
    expect(tracker.error, isNull);
  });
  test('deliberate visits to nodes near a diagonal remain detectable', () {
    final tracker = PatternTracker();
    tracker.accept({'type': 'DOWN', 'time': 100.0, 'x': 0.25, 'y': 0.25});
    tracker.accept({'type': 'MOVE', 'time': 100.1, 'x': 0.5, 'y': 0.25});
    tracker.accept({'type': 'MOVE', 'time': 100.2, 'x': 0.5, 'y': 0.5});
    tracker.accept({'type': 'UP', 'time': 100.3, 'x': 0.75, 'y': 0.5});
    expect(tracker.visits.map((v) => v.node), [1, 2, 5, 6]);
    expect(tracker.error, isNull);
  });
  test('touch clock anomaly does not stop drawing subsequent nodes', () {
    final tracker = PatternTracker();
    tracker.accept({'type': 'DOWN', 'time': 100.001, 'x': 0.25, 'y': 0.25});
    tracker.accept({'type': 'MOVE', 'time': 100.000, 'x': 0.50, 'y': 0.25});
    tracker.accept({'type': 'MOVE', 'time': 100.020, 'x': 0.75, 'y': 0.25});
    tracker.accept({'type': 'UP', 'time': 100.030, 'x': 0.75, 'y': 0.25});
    expect(tracker.visits.map((v) => v.node), [1, 2, 3]);
    expect(tracker.error, isNotNull);
    expect(tracker.touches.length, 4);
  });
  test('early DOWN is not reinterpreted as a new stroke inside the window', () {
    final tracker = PatternTracker();
    tracker.accept({'type': 'DOWN', 'time': 100.2, 'x': 0.25, 'y': 0.25},
        captureStart: 100.5, captureEnd: 104.5);
    tracker.accept({'type': 'MOVE', 'time': 100.7, 'x': 0.50, 'y': 0.25},
        captureStart: 100.5, captureEnd: 104.5);
    tracker.accept({'type': 'UP', 'time': 100.8, 'x': 0.75, 'y': 0.25},
        captureStart: 100.5, captureEnd: 104.5);
    expect(tracker.error, 'EARLY_TOUCH');
    expect(tracker.start, 100.2);
    expect(tracker.touches.where((e) => e.type == 'DOWN').length, 1);
  });
}
