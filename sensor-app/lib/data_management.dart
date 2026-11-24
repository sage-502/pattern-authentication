import 'model.dart';

enum TrialStatus { success, failed, review }

class TrialSummary {
  final String id, targetPattern, actualPattern, participantId, sessionId;
  final String displayName, reason, source, captureMode;
  final DateTime createdAt;
  final TrialStatus status;
  final int accelCount, gyroCount, mlRowCount;
  const TrialSummary(
      {required this.id,
      required this.targetPattern,
      required this.actualPattern,
      required this.participantId,
      required this.sessionId,
      required this.displayName,
      required this.reason,
      required this.source,
      required this.captureMode,
      required this.createdAt,
      required this.status,
      required this.accelCount,
      required this.gyroCount,
      required this.mlRowCount});

  factory TrialSummary.fromRecord(TrialRecord t) {
    final q = assess(t);
    final valid = q.result == 'matched' || q.result == 'mismatched';
    final status = !valid || !t.matched
        ? TrialStatus.failed
        : q.eligible
            ? TrialStatus.success
            : TrialStatus.review;
    final reason = !t.matched && valid
        ? 'TARGET_MISMATCH'
        : !valid
            ? (t.captureError ?? q.reason)
            : q.reason;
    return TrialSummary(
        id: t.id,
        targetPattern: t.target.join('-'),
        actualPattern: t.actual.join('-'),
        participantId: t.participantId,
        sessionId: t.sessionId,
        displayName: t.targetDisplayName,
        reason: reason,
        source: 'json_v1.1',
        captureMode: t.captureMode,
        createdAt: _createdAt(t.id),
        status: status,
        accelCount: t.sensors.where((s) => s.type == 'ACCEL').length,
        gyroCount: t.sensors.where((s) => s.type == 'GYRO').length,
        mlRowCount: q.joined.rows.length);
  }

  factory TrialSummary.legacyUnknown(String id,
          {String target = '',
          String actual = '',
          String participantId = ''}) =>
      TrialSummary(
          id: id,
          targetPattern: target.isEmpty ? '알 수 없음' : target,
          actualPattern: actual,
          participantId: participantId,
          sessionId: '',
          displayName: '',
          reason: 'LEGACY_UNKNOWN',
          source: 'legacy_csv',
          captureMode: TrialRecord.legacyMode,
          createdAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
          status: TrialStatus.review,
          accelCount: 0,
          gyroCount: 0,
          mlRowCount: 0);

  Map<String, dynamic> toJson() => {
        'id': id,
        'targetPattern': targetPattern,
        'actualPattern': actualPattern,
        'participantId': participantId,
        'sessionId': sessionId,
        'displayName': displayName,
        'reason': reason,
        'source': source,
        'captureMode': captureMode,
        'createdAt': createdAt.toIso8601String(),
        'status': status.name,
        'accelCount': accelCount,
        'gyroCount': gyroCount,
        'mlRowCount': mlRowCount
      };
  factory TrialSummary.fromJson(Map<String, dynamic> j) => TrialSummary(
      id: j['id'],
      targetPattern: j['targetPattern'],
      actualPattern: j['actualPattern'],
      participantId: j['participantId'],
      sessionId: j['sessionId'],
      displayName: j['displayName'] ?? '',
      reason: j['reason'] ?? '',
      source: j['source'] ?? 'json_v1.1',
      captureMode: j['captureMode'] ?? TrialRecord.legacyMode,
      createdAt: DateTime.parse(j['createdAt']),
      status: TrialStatus.values.byName(j['status']),
      accelCount: j['accelCount'] ?? 0,
      gyroCount: j['gyroCount'] ?? 0,
      mlRowCount: j['mlRowCount'] ?? 0);

  bool get fixedWindowSuccess =>
      status == TrialStatus.success &&
      captureMode == TrialRecord.fixedWindow5Mode;
  bool get legacySuccess =>
      status == TrialStatus.success &&
      (captureMode == TrialRecord.legacyMode ||
          captureMode == TrialRecord.fixedWindowMode);
}

DateTime _createdAt(String id) {
  final match = RegExp(r'^T(\d{13,16})').firstMatch(id);
  if (match == null) return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
  final value = int.parse(match.group(1)!);
  return DateTime.fromMicrosecondsSinceEpoch(
      match.group(1)!.length <= 13 ? value * 1000 : value,
      isUtc: true);
}

Map<String, List<TrialSummary>> groupTrials(Iterable<TrialSummary> trials) {
  final groups = <String, List<TrialSummary>>{};
  for (final trial in trials) {
    groups.putIfAbsent(trial.targetPattern, () => []).add(trial);
  }
  for (final group in groups.values) {
    group.sort((a, b) => b.createdAt.compareTo(a.createdAt));
  }
  return groups;
}

Set<String> selectedIds(Iterable<TrialSummary> all, Set<String> patternKeys,
        Set<String> trialIds) =>
    all
        .where((t) =>
            patternKeys.contains(t.targetPattern) || trialIds.contains(t.id))
        .map((t) => t.id)
        .toSet();
