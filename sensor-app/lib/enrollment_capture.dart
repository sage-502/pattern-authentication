import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/widgets.dart';

import 'capture.dart';
import 'model.dart';

enum EnrollmentCaptureState { idle, preparing, ready, recording, finishing }

/// v3 touch-bounded capture for enrollment.
///
/// There is no "start" button. [next] subscribes the IMU and waits for the
/// user's gesture: the attempt begins at the first pointer down on the board
/// and ends at the pointer up of the same gesture. A short pre-touch baseline
/// is retained for the claimant-weighted model.
///
/// The caller decides whether the returned trial is valid and should be
/// saved. A failed pattern or an invalid capture must never advance
/// enrollment.
class EnrollmentCaptureController extends ChangeNotifier
    with WidgetsBindingObserver {
  EnrollmentCaptureController({CaptureApi? api}) : _api = api ?? CaptureApi() {
    WidgetsBinding.instance.addObserver(this);
  }

  final CaptureApi _api;
  StreamSubscription<Map<String, dynamic>>? _touchSubscription;
  Completer<TrialRecord>? _active;
  final List<Map<String, dynamic>> _pendingTouches = [];

  EnrollmentCaptureState _state = EnrollmentCaptureState.idle;
  EnrollmentCaptureState get state => _state;
  bool get isBusy => _state != EnrollmentCaptureState.idle;
  PatternTracker? tracker;
  String? error;

  String? _userId;
  String? _sessionId;
  String? _deviceId;
  int? _attemptIndex;
  String _source = TrialRecord.enrollmentSource;
  bool _disposed = false;

  Future<TrialRecord> next({
    required String userId,
    required String sessionId,
    required int attemptIndex,
    required String deviceId,
    String source = TrialRecord.enrollmentSource,
  }) {
    if (_disposed) throw StateError('Capture controller is closed');
    if (isBusy) throw StateError('A capture is already running');
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) {
      throw StateError('앱을 다시 연 뒤 수집을 진행해 주세요.');
    }
    if (attemptIndex < 1 || attemptIndex > 5) {
      throw ArgumentError.value(attemptIndex, 'attemptIndex');
    }

    _userId = userId;
    _sessionId = sessionId;
    _deviceId = deviceId;
    _attemptIndex = attemptIndex;
    _source = source;
    _pendingTouches.clear();
    tracker = PatternTracker(rejectOutsideBoard: true);
    error = null;
    _active = Completer<TrialRecord>();
    _setState(EnrollmentCaptureState.preparing);
    unawaited(_begin());
    return _active!.future;
  }

  Future<void> _begin() async {
    try {
      await _cancelTouches();
      if (_state != EnrollmentCaptureState.preparing) return;
      _touchSubscription = _api.touches.listen(
        _onTouch,
        onError: (Object _) {
          tracker?.error = 'touch_channel_error';
          unawaited(_abort('터치 수집 오류가 발생했습니다. 다시 시도해 주세요.'));
        },
      );
      await _api.armTouch().timeout(const Duration(seconds: 5));
      if (_state != EnrollmentCaptureState.preparing) return;
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (_state != EnrollmentCaptureState.preparing) return;
      if (_pendingTouches.isNotEmpty) {
        _pendingTouches.clear();
        await _fail('센서 기준선 수집 중에 입력했습니다. 준비됨 표시 후 다시 시도해 주세요.');
        return;
      }
      final queued = List<Map<String, dynamic>>.of(_pendingTouches);
      _pendingTouches.clear();
      // A touch that started before both sensors were ready is still
      // processed; the quality check rejects it if coverage is insufficient.
      _setState(EnrollmentCaptureState.ready);
      for (final event in queued) {
        _onTouch(event);
      }
    } catch (e) {
      if (_state == EnrollmentCaptureState.preparing) {
        await _fail('센서를 시작할 수 없습니다: ${_describe(e)}');
      }
    }
  }

  void _onTouch(Map<String, dynamic> event) {
    if (_state == EnrollmentCaptureState.preparing) {
      _pendingTouches.add(event);
      return;
    }
    if (_state != EnrollmentCaptureState.ready &&
        _state != EnrollmentCaptureState.recording) {
      return;
    }
    try {
      final type = event['type'];
      tracker!.accept(event);
      if (type == 'DOWN') {
        _setState(EnrollmentCaptureState.recording);
      } else if (type == 'UP' || type == 'CANCEL' || type == 'MULTITOUCH') {
        unawaited(_finish());
      } else {
        _notify();
      }
    } catch (_) {
      tracker?.error = 'touch_channel_error';
      unawaited(_abort('터치 데이터 오류가 발생했습니다. 다시 시도해 주세요.'));
    }
  }

  Future<void> _abort(String reason) async {
    if (!isBusy || _state == EnrollmentCaptureState.finishing) return;
    await _fail(reason);
  }

  Future<void> _finish() async {
    if (!isBusy || _state == EnrollmentCaptureState.finishing) return;
    _setState(EnrollmentCaptureState.finishing);
    try {
      final native =
          await _api.finishTouch().timeout(const Duration(seconds: 3));
      final t = tracker ?? PatternTracker();
      final raw = (native['sensors'] as List? ?? [])
          .map((e) => SensorSample.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      final start = t.start ?? _nativeSeconds(native['start']) ?? 0;
      final end = t.end ?? _nativeSeconds(native['end']) ?? start;
      final captureError = t.error ??
          (t.start == null
              ? 'NO_TOUCH_DOWN'
              : t.end == null
                  ? 'NO_TOUCH_UP'
                  : native['drained'] == false
                      ? 'SENSOR_DRAIN_TIMEOUT'
                      : null);
      final record = TrialRecord(
        id: _id(),
        sessionId: _sessionId!,
        index: _attemptIndex!,
        participantId: _userId!,
        deviceId: _deviceId!,
        hand: 'unknown',
        posture: 'unknown',
        holdingHand: 'unknown',
        // The repository compares this sequence with the private verifier
        // before saving it as research data. The UI never draws a target guide.
        target: List.of(t.visits.map((v) => v.node)),
        visits: List.of(t.visits),
        touches: List.of(t.touches),
        sensors: raw,
        start: start,
        end: end,
        clockErrorMs: (native['clockErrorMs'] as num?)?.toDouble() ?? 0,
        platform: Platform.operatingSystem,
        model: native['model']?.toString() ?? '',
        osVersion: native['osVersion']?.toString() ?? '',
        captureError: captureError,
        captureMode: TrialRecord.touchCalibratedMode,
        hitRadiusNorm: PatternTracker.hitRadius,
        actualTouchDown: t.start,
        actualTouchUp: t.end,
        windowComplete: t.start != null && t.end != null,
        source: _source,
        sensorTimestampBasis: native['sensorTimestampBasis']?.toString() ??
            'elapsedRealtimeNanos',
      );
      _active?.complete(record);
    } catch (e) {
      error = _describe(e);
      if (_active?.isCompleted == false) {
        _active!.completeError(StateError('수집을 마치지 못했습니다. 다시 시도해 주세요.'));
      }
      try {
        await _api.cancel();
      } catch (_) {}
    } finally {
      await _cancelTouches();
      _active = null;
      _setState(EnrollmentCaptureState.idle);
    }
  }

  Future<void> _fail(String reason) async {
    try {
      await _api.cancel();
    } catch (_) {
      // The original error is the one to show to the user.
    }
    await _cancelTouches();
    error = reason;
    if (_active?.isCompleted == false) {
      _active!.completeError(StateError(reason));
    }
    _active = null;
    _setState(EnrollmentCaptureState.idle);
  }

  static String _describe(Object e) => e is TimeoutException
      ? '응답 시간이 초과됐습니다.'
      : e.toString().replaceFirst('Bad state: ', '');

  static double? _nativeSeconds(Object? value) =>
      value is num ? value.toDouble() : null;

  static String _id() =>
      'T${DateTime.now().microsecondsSinceEpoch}_${Random.secure().nextInt(0xffffff).toRadixString(16)}';

  void _setState(EnrollmentCaptureState value) {
    _state = value;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && isBusy) {
      unawaited(_abort('앱이 중단되어 수집을 취소했습니다. 다시 시도해 주세요.'));
    }
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    if (_active?.isCompleted == false) {
      _active!.completeError(StateError('수집 화면이 닫혔습니다.'));
    }
    _active = null;
    unawaited(_closeNative());
    super.dispose();
  }

  Future<void> _closeNative() async {
    await _cancelTouches();
    try {
      await _api.cancel();
    } catch (_) {}
  }

  Future<void> _cancelTouches() async {
    final subscription = _touchSubscription;
    _touchSubscription = null;
    try {
      await subscription?.cancel();
    } catch (_) {}
  }
}
