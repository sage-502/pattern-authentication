import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import 'behavior_auth.dart';
import 'claimant_weighted_auth.dart';
import 'data_management.dart';
import 'model.dart';
import 'storage.dart';
import 'training_import.dart';

/// The research trial remains the source of truth for every completed attempt.
/// The user and verifier files only describe how those trials are grouped.
String enrollmentSessionId(String userId, int sessionIndex) {
  if (sessionIndex != 1 && sessionIndex != 2) {
    throw ArgumentError.value(sessionIndex, 'sessionIndex');
  }
  return 'enrollment_${sha256.convert(utf8.encode(userId))}_s$sessionIndex';
}

/// Session under which successful login captures are stored as additional
/// training data while the user's valid data is below [validDataTarget].
String loginSessionId(String userId) =>
    'login_${sha256.convert(utf8.encode(userId))}';

/// Valid data (enrollment + stored login captures + imported trials) at
/// which login captures stop being stored, the behavior model is trained
/// once, and login requires the behavioral second factor.
const validDataTarget = weightedEnrollmentCount;

/// Which factors a login needs, decided from the valid data at login start.
enum LoginPhase {
  /// Below [validDataTarget]: pattern only (a manually trained model is not
  /// used yet).
  patternOnly,

  /// [validDataTarget] or more and a model exists: pattern + behavior.
  behavior,

  /// [validDataTarget] or more but no model: the login is held, never
  /// downgraded to pattern only.
  modelNotReady,
}

LoginPhase loginPhaseOf(EnrollmentProfile profile) =>
    profile.validDataCount < validDataTarget
        ? LoginPhase.patternOnly
        : profile.model == null
            ? LoginPhase.modelNotReady
            : LoginPhase.behavior;

enum EnrollmentStage {
  draft,
  collectingSession1,
  regripRequired,
  collectingSession2,
  completed,
}

class EnrollmentRecord {
  final String recordId;
  final int sessionIndex;
  final int attemptIndex;
  final DateTime capturedAt;
  final double patternStartAt;
  final double patternEndAt;
  final String sensorDataRef;
  final String captureStatus;
  final String captureMode;

  const EnrollmentRecord({
    required this.recordId,
    required this.sessionIndex,
    required this.attemptIndex,
    required this.capturedAt,
    required this.patternStartAt,
    required this.patternEndAt,
    required this.sensorDataRef,
    this.captureStatus = 'SAVED',
    this.captureMode = TrialRecord.touchBoundedMode,
  });

  /// True for records captured from first touch down to touch up (v3).
  bool get isTouchBounded =>
      captureMode == TrialRecord.touchBoundedMode ||
      captureMode == TrialRecord.touchCalibratedMode;
}

class EnrollmentProfile {
  final String userId;
  final String displayName;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool hasPattern;
  final bool regripAcknowledged;
  final String? patternVerifierRef;
  final List<EnrollmentRecord> records;

  /// Training trials imported from research-collector ZIPs (v3.1). They are
  /// stored separately and never count toward the ten enrollment captures.
  final int importedTrialCount;
  final int importBatchCount;

  /// v3.2 prototype behavior model (null = not trained).
  final BehaviorModelInfo? model;

  /// Successful login captures stored as training data, oldest first.
  final List<String> loginRecordIds;

  EnrollmentProfile({
    required this.userId,
    required this.displayName,
    required this.createdAt,
    required this.updatedAt,
    required this.hasPattern,
    required this.regripAcknowledged,
    required this.patternVerifierRef,
    required List<EnrollmentRecord> records,
    this.importedTrialCount = 0,
    this.importBatchCount = 0,
    this.model,
    List<String> loginRecordIds = const [],
  })  : records = List.unmodifiable(records),
        loginRecordIds = List.unmodifiable(loginRecordIds);

  int get session1Count => records.where((r) => r.sessionIndex == 1).length;
  int get session2Count => records.where((r) => r.sessionIndex == 2).length;
  int get totalCount => session1Count + session2Count;

  /// Valid data: enrollment captures, stored login captures and imported
  /// research trials (counted for research use).
  int get validDataCount =>
      totalCount + loginRecordIds.length + importedTrialCount;
  bool get collectsLoginData => isComplete && validDataCount < validDataTarget;
  bool get isComplete =>
      hasPattern &&
      regripAcknowledged &&
      session1Count == 5 &&
      session2Count == 5;
  String get registrationStatus => isComplete ? 'COMPLETED' : 'IN_PROGRESS';
  String get modelStatus =>
      model == null ? '미학습' : '학습됨 (${model!.trainedWithCount}개 · 프로토타입)';

  EnrollmentStage get stage {
    if (!hasPattern) return EnrollmentStage.draft;
    if (session1Count < 5) return EnrollmentStage.collectingSession1;
    if (!regripAcknowledged) return EnrollmentStage.regripRequired;
    if (session2Count < 5) return EnrollmentStage.collectingSession2;
    return EnrollmentStage.completed;
  }
}

/// Capture modes counted toward enrollment. Records saved by the earlier
/// five-second build stay valid so existing enrollment data is preserved.
const _enrollmentModes = {
  TrialRecord.touchBoundedMode,
  TrialRecord.touchCalibratedMode,
  TrialRecord.fixedWindow5Mode,
};

class EnrollmentRepository {
  final SessionStorage storage;
  Future<void> _lastMutation = Future<void>.value();

  EnrollmentRepository(this.storage);

  Directory get _users => Directory('${storage.root.path}/enrollment/users');
  Directory get _verifiers =>
      Directory('${storage.root.path}/enrollment/verifiers');

  String _fileKey(String userId) =>
      sha256.convert(utf8.encode(userId)).toString();
  File _userFile(String userId) =>
      File('${_users.path}/${_fileKey(userId)}.json');
  File _verifierFile(String userId) =>
      File('${_verifiers.path}/${_fileKey(userId)}.json');
  String _verifierRef(String userId) =>
      'enrollment/verifiers/${_fileKey(userId)}.json';

  Future<T> _serialize<T>(Future<T> Function() action) async {
    final previous = _lastMutation;
    final done = Completer<void>();
    _lastMutation = done.future;
    await previous;
    try {
      return await action();
    } finally {
      done.complete();
    }
  }

  Future<EnrollmentProfile> createUser({
    required String userId,
    required String displayName,
  }) =>
      _serialize(() async {
        final id = userId.trim();
        final name = displayName.trim();
        if (!RegExp(r'^[A-Za-z0-9_-]{1,64}$').hasMatch(id)) {
          throw ArgumentError.value(
              userId, 'userId', '영문, 숫자, 밑줄, 하이픈으로 1~64자를 입력해 주세요.');
        }
        if (name.isEmpty ||
            name.length > 80 ||
            RegExp(r'[\x00-\x1f\x7f]').hasMatch(name)) {
          throw ArgumentError.value(
              displayName, 'displayName', '이름은 1~80자로 입력해 주세요.');
        }
        final file = _userFile(id);
        if (await file.exists()) throw StateError('이미 사용 중인 사용자 ID입니다.');
        final now = DateTime.now().toUtc().toIso8601String();
        await _writeJson(file, {
          'userId': id,
          'displayName': name,
          'createdAt': now,
          'updatedAt': now,
          'regripAcknowledged': false,
        });
        return (await getUser(id))!;
      });

  Future<List<EnrollmentProfile>> getUsers() async {
    if (!await _users.exists()) return [];
    final files = await _users
        .list()
        .where((entry) => entry is File && entry.path.endsWith('.json'))
        .cast<File>()
        .toList();
    final result = <EnrollmentProfile>[];
    for (final file in files) {
      final json = await _readJson(file);
      final id = json['userId'];
      if (id is! String) continue;
      final profile = await getUser(id);
      if (profile != null) result.add(profile);
    }
    result.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return result;
  }

  Future<EnrollmentProfile?> getUser(String userId) async {
    final file = _userFile(userId);
    if (!await file.exists()) return null;
    final user = await _readJson(file);
    if (user['userId'] != userId) {
      throw const FormatException('User ID mismatch');
    }
    final verifier = await _loadVerifier(userId);
    final records = verifier == null
        ? <EnrollmentRecord>[]
        : await _validRecords(userId, verifier);
    final loginIds = verifier == null
        ? <String>[]
        : await _validLoginRecordIds(userId, verifier);
    final imports = await _importBatches(userId);
    final createdAt = DateTime.parse(user['createdAt'] as String);
    final profileUpdatedAt = DateTime.parse(user['updatedAt'] as String);
    final patternUpdatedAt = verifier?.confirmedAt;
    final newestCapture = records.isEmpty
        ? profileUpdatedAt
        : records.map((r) => r.capturedAt).reduce(
              (a, b) => a.isAfter(b) ? a : b,
            );
    final latest = [
      profileUpdatedAt,
      newestCapture,
      if (patternUpdatedAt != null) patternUpdatedAt,
    ].reduce((a, b) => a.isAfter(b) ? a : b);
    return EnrollmentProfile(
      userId: userId,
      displayName: user['displayName'] as String,
      createdAt: createdAt,
      updatedAt: latest,
      hasPattern: verifier != null,
      regripAcknowledged: user['regripAcknowledged'] == true,
      patternVerifierRef: verifier == null ? null : _verifierRef(userId),
      records: records,
      importedTrialCount:
          imports.fold(0, (sum, batch) => sum + batch.trialIds.length),
      importBatchCount: imports.length,
      model: await _loadModelInfo(userId),
      loginRecordIds: loginIds,
    );
  }

  Future<EnrollmentProfile> confirmPattern(String userId, List<int> nodes) =>
      _serialize(() async {
        final profile = await getUser(userId);
        if (profile == null) throw StateError('사용자를 찾을 수 없습니다.');
        if (profile.hasPattern) throw StateError('이미 패턴이 설정되었습니다.');
        final pattern = _validPattern(nodes);
        final random = Random.secure();
        final salt = List<int>.generate(32, (_) => random.nextInt(256));
        final file = _verifierFile(userId);
        await _writeJson(file, {
          'version': 1,
          'salt': base64Encode(salt),
          'digest': _digest(salt, pattern),
          'confirmedAt': DateTime.now().toUtc().toIso8601String(),
        });
        return (await getUser(userId))!;
      });

  Future<bool> matchesPattern(String userId, List<int> nodes) async {
    final verifier = await _loadVerifier(userId);
    if (verifier == null) return false;
    List<int> pattern;
    try {
      pattern = _validPattern(nodes);
    } on ArgumentError {
      return false;
    }
    return _matches(verifier, pattern);
  }

  Future<EnrollmentProfile> acknowledgeRegrip(String userId) =>
      _serialize(() async {
        final profile = await getUser(userId);
        if (profile == null) throw StateError('사용자를 찾을 수 없습니다.');
        if (profile.session1Count != 5) {
          throw StateError('1차 수집 5회를 먼저 완료해 주세요.');
        }
        if (profile.regripAcknowledged) return profile;
        final file = _userFile(userId);
        final json = await _readJson(file);
        json['regripAcknowledged'] = true;
        json['updatedAt'] = DateTime.now().toUtc().toIso8601String();
        await _writeJson(file, json);
        return (await getUser(userId))!;
      });

  Future<EnrollmentProfile> saveCapture(
          String userId, int sessionIndex, TrialRecord trial) =>
      _serialize(() async {
        final profile = await getUser(userId);
        if (profile == null || !profile.hasPattern) {
          throw StateError('패턴이 설정된 사용자를 찾을 수 없습니다.');
        }
        if (sessionIndex != 1 && sessionIndex != 2) {
          throw ArgumentError.value(sessionIndex, 'sessionIndex');
        }
        if (sessionIndex == 1 &&
                profile.stage != EnrollmentStage.collectingSession1 ||
            sessionIndex == 2 &&
                profile.stage != EnrollmentStage.collectingSession2) {
          throw StateError('현재 수집 단계와 회차가 일치하지 않습니다.');
        }
        final expectedIndex = sessionIndex == 1
            ? profile.session1Count + 1
            : profile.session2Count + 1;
        if (trial.participantId != userId ||
            trial.sessionId != enrollmentSessionId(userId, sessionIndex) ||
            trial.index != expectedIndex ||
            !RegExp(r'^T[\w-]+$').hasMatch(trial.id)) {
          throw StateError('수집 기록의 사용자, 세션 또는 회차가 일치하지 않습니다.');
        }
        if (await storage.loadTrial(trial.id) != null) {
          throw StateError('이미 저장된 수집 ID입니다.');
        }
        final verifier = await _loadVerifier(userId);
        if (verifier == null || !_matches(verifier, trial.actual)) {
          throw StateError('설정한 패턴과 다릅니다. 다시 입력해 주세요.');
        }
        // New enrollment attempts must use the v3 touch-bounded window.
        if (trial.captureMode != TrialRecord.touchBoundedMode &&
                trial.captureMode != TrialRecord.touchCalibratedMode ||
            trial.source != TrialRecord.enrollmentSource ||
            TrialSummary.fromRecord(trial).status != TrialStatus.success) {
          throw StateError('센서 또는 시각 데이터가 유효하지 않습니다. 다시 시도해 주세요.');
        }
        try {
          await storage.saveTrial(trial);
        } catch (_) {
          // saveTrial writes the source JSON before rebuilding its summary.
          // A complete source is still a valid attempt; loadSummaries repairs
          // the missing summary on the next read.
          final source = await storage.loadTrial(trial.id);
          if (source == null ||
              TrialSummary.fromRecord(source).status != TrialStatus.success) {
            rethrow;
          }
        }
        final saved = await storage.loadTrial(trial.id);
        if (saved == null ||
            TrialSummary.fromRecord(saved).status != TrialStatus.success) {
          throw StateError('원본 데이터 저장을 확인할 수 없습니다.');
        }
        final updated = (await getUser(userId))!;
        if (!updated.records.any((record) => record.recordId == trial.id)) {
          throw StateError('수집 기록의 영속 저장을 확인할 수 없습니다.');
        }
        return updated;
      });

  /// Stores a successful login capture as training data while the user's
  /// valid data (enrollment + stored logins) is below [validDataTarget].
  /// When this capture brings the count to the target, the behavior model is
  /// trained once automatically. Later logins are not stored, so the model
  /// is never retrained automatically; manual retraining stays available.
  Future<LoginCaptureResult> saveLoginCapture(
          String userId, TrialRecord trial) =>
      _serialize(() async {
        final profile = await getUser(userId);
        if (profile == null || !profile.hasPattern) {
          throw StateError('패턴이 설정된 사용자를 찾을 수 없습니다.');
        }
        final before = profile.validDataCount;
        if (!profile.isComplete || before >= validDataTarget) {
          return LoginCaptureResult(stored: false, validDataCount: before);
        }
        if (trial.participantId != userId ||
            trial.sessionId != loginSessionId(userId) ||
            !RegExp(r'^T[\w-]+$').hasMatch(trial.id)) {
          throw StateError('로그인 기록의 사용자 또는 세션이 일치하지 않습니다.');
        }
        if (await storage.loadTrial(trial.id) != null) {
          throw StateError('이미 저장된 수집 ID입니다.');
        }
        final verifier = await _loadVerifier(userId);
        if (verifier == null || !_matches(verifier, trial.actual)) {
          throw StateError('설정한 패턴과 다릅니다.');
        }
        if (trial.captureMode != TrialRecord.touchBoundedMode &&
                trial.captureMode != TrialRecord.touchCalibratedMode ||
            TrialSummary.fromRecord(trial).status != TrialStatus.success) {
          throw StateError('센서 또는 시각 데이터가 유효하지 않습니다.');
        }
        try {
          await storage.saveTrial(trial);
        } catch (_) {
          final source = await storage.loadTrial(trial.id);
          if (source == null ||
              TrialSummary.fromRecord(source).status != TrialStatus.success) {
            rethrow;
          }
        }
        final updated = (await getUser(userId))!;
        if (!updated.loginRecordIds.contains(trial.id)) {
          throw StateError('로그인 기록의 영속 저장을 확인할 수 없습니다.');
        }
        final after = updated.validDataCount;
        BehaviorModelInfo? autoTrained;
        String? autoTrainError;
        if (after >= validDataTarget) {
          try {
            autoTrained = await _trainModelLocked(userId, trigger: 'auto');
          } catch (e) {
            autoTrainError = e.toString();
          }
        }
        return LoginCaptureResult(
          stored: true,
          validDataCount: after,
          autoTrained: autoTrained,
          autoTrainError: autoTrainError,
        );
      });

  /// Removes everything stored for [userId]: profile, pattern verifier,
  /// enrollment and login raw records and their index entries, imported
  /// training data and the model. This cannot be undone.
  Future<void> deleteUser(String userId) => _serialize(() async {
        final file = _userFile(userId);
        if (!await file.exists()) throw StateError('사용자를 찾을 수 없습니다.');
        final user = await _readJson(file);
        if (user['userId'] != userId) {
          throw const FormatException('User ID mismatch');
        }
        final sessions = {
          enrollmentSessionId(userId, 1),
          enrollmentSessionId(userId, 2),
          loginSessionId(userId),
        };
        for (final summary in await storage.loadSummaries()) {
          if (summary.participantId != userId ||
              !sessions.contains(summary.sessionId) ||
              !RegExp(r'^T[\w-]+$').hasMatch(summary.id)) {
            continue;
          }
          for (final f in [
            File('${storage.records.path}/${summary.id}.json'),
            File('${storage.index.path}/${summary.id}.json'),
          ]) {
            if (await f.exists()) await f.delete();
          }
        }
        final imports = _importDir(userId);
        if (await imports.exists()) await imports.delete(recursive: true);
        final model = _modelFile(userId);
        if (await model.exists()) await model.delete();
        final verifier = _verifierFile(userId);
        if (await verifier.exists()) await verifier.delete();
        // The profile goes last so a failure part-way leaves the user visible
        // and the deletion can be retried.
        await file.delete();
      });

  /// Imports one research-collector export ZIP as training data for
  /// [userId]. Only trials whose pattern matches the user's registered
  /// pattern are kept; their original CSV lines are written unchanged under
  /// `imports/<user key>/<import id>/` in app-internal storage.
  Future<TrainingImportResult> importTrainingZip(
    String userId,
    Uint8List bytes, {
    required String sourceName,
  }) =>
      _serialize(() async {
        final profile = await getUser(userId);
        if (profile == null) throw StateError('사용자를 찾을 수 없습니다.');
        final before = profile.validDataCount;
        final verifier = await _loadVerifier(userId);
        if (verifier == null) {
          throw StateError('패턴을 설정한 사용자에게만 가져올 수 있습니다.');
        }
        final export = parseResearchExport(bytes);
        final existing = {
          for (final batch in await _importBatches(userId)) ...batch.trialIds
        };
        final accepted = <ExportTrial>[];
        var mismatched = 0, duplicate = 0, noSensor = 0;
        for (final trial in export.trials) {
          if (!_matches(verifier, trial.pattern)) {
            mismatched++;
          } else if (existing.contains(trial.trialId)) {
            duplicate++;
          } else if ((export.sensorLines[trial.trialId] ?? const []).isEmpty) {
            noSensor++;
          } else {
            accepted.add(trial);
          }
        }
        final result = TrainingImportResult(
          sourceName: sourceName,
          imported: accepted.length,
          patternMismatch: mismatched,
          duplicate: duplicate,
          missingSensor: noSensor,
        );
        if (accepted.isEmpty) return result;

        final importId =
            'I${DateTime.now().microsecondsSinceEpoch}_${Random.secure().nextInt(0xffffff).toRadixString(16)}';
        final target = Directory('${_importDir(userId).path}/$importId');
        final temp = Directory('${target.path}.tmp');
        await temp.create(recursive: true);
        try {
          Future<void> write(String name, Iterable<String> lines) =>
              File('${temp.path}/$name')
                  .writeAsString('${lines.join('\r\n')}\r\n', flush: true);
          await write('trials.csv',
              [export.trialsHeader, ...accepted.map((t) => t.line)]);
          await write('sensor_events.csv', [
            export.sensorHeader,
            for (final t in accepted) ...export.sensorLines[t.trialId]!,
          ]);
          final metadataHeader = export.metadataHeader;
          if (metadataHeader != null) {
            await write('fixed_window_metadata.csv', [
              metadataHeader,
              for (final t in accepted)
                if (export.metadataLines[t.trialId] != null)
                  export.metadataLines[t.trialId]!,
            ]);
          }
          final manifest = export.manifestText;
          if (manifest != null) {
            await File('${temp.path}/export_manifest.csv')
                .writeAsString(manifest, flush: true);
          }
          await File('${temp.path}/import.json').writeAsString(
            jsonEncode({
              'version': 1,
              'importId': importId,
              'userId': userId,
              'source': 'IMPORT',
              'sourceFileName': sourceName,
              'sourceExportId': export.exportId,
              'sourceParticipantIds':
                  accepted.map((t) => t.participantId).toSet().toList(),
              'importedAt': DateTime.now().toUtc().toIso8601String(),
              'trialIds': accepted.map((t) => t.trialId).toList(),
              'skippedPatternMismatch': mismatched,
              'skippedDuplicate': duplicate,
              'skippedMissingSensor': noSensor,
            }),
            flush: true,
          );
          await temp.rename(target.path);
        } finally {
          if (await temp.exists()) await temp.delete(recursive: true);
        }
        // Reaching the target through an import also trains the model once.
        final after = (await getUser(userId))!.validDataCount;
        if (before < validDataTarget && after >= validDataTarget) {
          try {
            return result.withAutoTraining(
                await _trainModelLocked(userId, trigger: 'auto'), null);
          } catch (e) {
            return result.withAutoTraining(null, e.toString());
          }
        }
        return result;
      });

  Directory _importDir(String userId) =>
      Directory('${storage.root.path}/imports/${_fileKey(userId)}');

  Future<List<_ImportBatch>> _importBatches(String userId) async {
    final dir = _importDir(userId);
    if (!await dir.exists()) return const [];
    final batches = <_ImportBatch>[];
    await for (final entry in dir.list()) {
      if (entry is! Directory || entry.path.endsWith('.tmp')) continue;
      final meta = File('${entry.path}/import.json');
      if (!await meta.exists()) continue;
      try {
        final json = await _readJson(meta);
        if (json['userId'] != userId) continue;
        batches.add(_ImportBatch(
            (json['trialIds'] as List).whereType<String>().toList()));
      } catch (_) {
        // A damaged batch is ignored rather than counted.
      }
    }
    return batches;
  }

  // ------------------------------------------------ v3.2 behavior model

  File _modelFile(String userId) =>
      File('${storage.root.path}/models/${_fileKey(userId)}.json');

  /// Training samples of [userId]: valid data (enrollment records, imported
  /// research trials and stored login captures, all limited to the touch
  /// window) in the order it entered the app, and of that only the first
  /// [validDataTarget]. Enrollment and login records are ordered by their
  /// capture time (encoded in the record ID), imported trials by the time of
  /// their import and then by their order in the ZIP. Trials whose samples
  /// cannot be computed are skipped and the next ones fill their place.
  Future<TrainingSet> trainingSet(String userId) async {
    final profile = await getUser(userId);
    if (profile == null) throw StateError('사용자를 찾을 수 없습니다.');
    final entries = <_TrainingEntry>[];
    Future<TrainingExample?> fromStored(String id, String source) async {
      final trial = await storage.loadTrial(id);
      if (trial == null) return null;
      final rows = touchRowsFromTrial(trial);
      final nodes = [for (final visit in trial.visits) visit.time];
      final down = trial.actualTouchDown ?? trial.start;
      final up = trial.actualTouchUp ?? trial.end;
      return TrainingExample(id, source, rows, nodes, down, up,
          BehaviorSample.fromRows(rows, nodes, down, up));
    }

    for (final record in profile.records) {
      entries.add(_TrainingEntry(_arrivalOf(record.recordId), 0, 'enrollment',
          () => fromStored(record.recordId, 'enrollment')));
    }
    for (final id in profile.loginRecordIds) {
      entries.add(_TrainingEntry(
          _arrivalOf(id), 0, 'login', () => fromStored(id, 'login')));
    }
    final dir = _importDir(userId);
    if (await dir.exists()) {
      await for (final entry in dir.list()) {
        if (entry is! Directory || entry.path.endsWith('.tmp')) continue;
        final meta = File('${entry.path}/import.json');
        if (!await meta.exists()) continue;
        DateTime importedAt;
        try {
          importedAt =
              DateTime.parse((await _readJson(meta))['importedAt'] as String);
        } catch (_) {
          importedAt = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
        }
        final trials = await _readImportedTrials(entry);
        for (var i = 0; i < trials.length; i++) {
          final trial = trials[i];
          entries.add(_TrainingEntry(
              importedAt,
              i,
              'imported',
              () async => TrainingExample(
                  trial.id,
                  'imported',
                  trial.rows,
                  trial.nodes,
                  trial.down,
                  trial.up,
                  BehaviorSample.fromRows(
                      trial.rows, trial.nodes, trial.down, trial.up))));
        }
      }
    }
    entries.sort((a, b) {
      final t = a.arrival.compareTo(b.arrival);
      return t != 0 ? t : a.order.compareTo(b.order);
    });

    final usable = <TrainingExample>[];
    var skipped = 0;
    for (final e in entries) {
      try {
        final sample = await e.load();
        if (sample == null) {
          skipped++;
        } else {
          usable.add(sample);
        }
      } on BehaviorFeatureException {
        skipped++;
      }
    }
    // Samples must share the enrolled pattern length (timing features).
    final lengths = <int, int>{};
    for (final example in usable) {
      final length = example.sample.timing.length;
      lengths[length] = (lengths[length] ?? 0) + 1;
    }
    if (lengths.length > 1) {
      final common =
          lengths.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
      final before = usable.length;
      usable.removeWhere((u) => u.sample.timing.length != common);
      skipped += before - usable.length;
    }
    final used = usable.take(validDataTarget).toList();
    int count(String source) => used.where((u) => u.source == source).length;
    return TrainingSet(
      [for (final example in used) example.sample],
      count('enrollment'),
      count('imported'),
      skipped,
      login: count('login'),
      available: usable.length,
      examples: used,
    );
  }

  /// ZIP of the exact input rows and derived samples selected by trainingSet.
  /// A model trained before the current 40-record selection cannot be
  /// represented as the active model's training data and is rejected.
  Future<File> exportModelTrainingData(String userId) async {
    final profile = await getUser(userId);
    if (profile == null || profile.model == null) {
      throw StateError('학습된 행동 모델이 없습니다.');
    }
    final set = await trainingSet(userId);
    if (profile.model!.trainedWithCount != validDataTarget ||
        set.examples.length != validDataTarget) {
      throw StateError('현재 모델의 학습 기록 $validDataTarget개를 확인할 수 없습니다.');
    }
    final saved = await _readModelJson(userId);
    if (saved == null ||
        jsonEncode(saved['selectedIds']) !=
            jsonEncode([for (final example in set.examples) example.id])) {
      throw StateError('저장된 모델의 학습 입력과 현재 기록이 일치하지 않습니다.');
    }
    final manifest = <String, Object?>{
      'schema_version': 1,
      'purpose': 'behavior_model_training_inputs',
      'user_id': userId,
      'pipeline': weightedPipelineVersion,
      'exported_at_utc': DateTime.now().toUtc().toIso8601String(),
      'model_trained_at_utc':
          profile.model!.trainedAt.toUtc().toIso8601String(),
      'model_training_count': profile.model!.trainedWithCount,
      'selected_count': set.examples.length,
      'source_counts': {
        'enrollment': set.enrollment,
        'login': set.login,
        'imported': set.imported,
      },
      'threshold': profile.model!.threshold,
      'selection': 'first 40 usable trials in app arrival order',
      'partition': 'all 40 selected trials fit the app model',
    };
    final trials = <String>[
      'export_index,trial_id,source,partition,touch_down,touch_up,node_timestamps,sensor_row_count'
    ];
    final sensors = <String>[
      'export_index,trial_id,timestamp,ax,ay,az,gx,gy,gz'
    ];
    final fullSensors = <String>[
      'export_index,trial_id,timestamp,ax,ay,az,gx,gy,gz'
    ];
    final features = <String>[
      'export_index,trial_id,${weightedFeatures.join(',')}'
    ];
    for (var i = 0; i < set.examples.length; i++) {
      final e = set.examples[i];
      final index = i + 1;
      const partition = 'fit';
      final trial = await storage.loadTrial(e.id);
      if (trial == null) throw StateError('원본 기록이 없습니다: ${e.id}');
      trials.add(csvRow([
        index,
        e.id,
        e.source,
        partition,
        e.down,
        e.up,
        jsonEncode(e.nodes),
        e.rows.length
      ]));
      for (final row in e.rows) {
        sensors.add(csvRow([index, e.id, ...row]));
      }
      final raw = joinSensors(
              trial.sensors, trial.sensors.map((s) => s.time).reduce(min), e.up)
          .rows;
      for (final r in raw) {
        fullSensors.add(
            csvRow([index, e.id, r.time, r.ax, r.ay, r.az, r.gx, r.gy, r.gz]));
      }
      features.add(csvRow([index, e.id, ...weightedFeaturesFromTrial(trial)]));
    }
    final archive = Archive();
    void add(String name, String content) {
      final bytes = utf8.encode(content);
      archive.addFile(ArchiveFile(name, bytes.length, bytes));
    }

    add('manifest.json', const JsonEncoder.withIndent('  ').convert(manifest));
    add('training_trials.csv', '${trials.join('\r\n')}\r\n');
    add('sensor_rows.csv', '${sensors.join('\r\n')}\r\n');
    add('pre_touch_sensor_rows.csv', '${fullSensors.join('\r\n')}\r\n');
    add('model_features.csv', '${features.join('\r\n')}\r\n');
    add(
        'README.txt',
        '선택된 사용자 한 명의 v4.2 행동 모델 학습 자료 40개입니다.\n'
            '40개 전체로 모델을 학습합니다.\n'
            'sensor_rows.csv는 터치 구간, pre_touch_sensor_rows.csv는 기준선을 포함한 6축 행입니다.\n'
            'model_features.csv는 23개 모델 입력 특징입니다.\n'
            '시각과 센서 기록은 민감한 개인 데이터이므로 공유 대상을 확인하세요.\n');
    final encoded = ZipEncoder().encode(archive);
    await storage.exports.create(recursive: true);
    final stamp = DateTime.now().toUtc().millisecondsSinceEpoch;
    final key = _fileKey(userId).substring(0, 12);
    final file =
        File('${storage.exports.path}/behavior_training_${key}_$stamp.zip');
    await file.writeAsBytes(encoded, flush: true);
    return file;
  }

  /// Wall-clock capture time encoded in an app record ID (`T<µs>_...`).
  DateTime _arrivalOf(String recordId) {
    final match = RegExp(r'^T(\d{13,16})').firstMatch(recordId);
    if (match == null) {
      return DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
    }
    final value = int.parse(match.group(1)!);
    return DateTime.fromMicrosecondsSinceEpoch(
        match.group(1)!.length <= 13 ? value * 1000 : value,
        isUtc: true);
  }

  /// Fits the claimant-weighted model from one user's 40 records.
  Future<BehaviorModelInfo> trainModel(String userId) =>
      _serialize(() => _trainModelLocked(userId, trigger: 'manual'));

  /// [trigger] is 'manual' (profile button) or 'auto' (valid data reached
  /// [validDataTarget] at a login). Call only inside [_serialize].
  Future<BehaviorModelInfo> _trainModelLocked(String userId,
      {required String trigger}) async {
    final ownSet = await trainingSet(userId);
    if (ownSet.examples.length != validDataTarget) {
      throw StateError('사용자별 기록 $validDataTarget개가 필요합니다.');
    }
    final first = await storage.loadTrial(ownSet.examples.first.id);
    if (first == null || first.captureMode != TrialRecord.touchCalibratedMode) {
      throw StateError('새 기준선 수집 방식으로 다시 등록한 기록이 필요합니다.');
    }
    final rows = <List<double>>[];
    for (final example in ownSet.examples) {
      final trial = await storage.loadTrial(example.id);
      if (trial == null ||
          trial.deviceId != first.deviceId ||
          trial.captureMode != TrialRecord.touchCalibratedMode ||
          trial.actual.join('-') != first.actual.join('-')) {
        throw StateError(
            '$validDataTarget개 기록 중 새 수집 방식·패턴·기기가 일치하지 않는 기록이 있습니다.');
      }
      try {
        rows.add(weightedFeaturesFromTrial(trial));
      } on WeightedFeatureException catch (e) {
        throw StateError('기록 ${example.id}: $e');
      }
    }
    final model = fitWeightedClaimant(rows);
    final trainedAt = DateTime.now().toUtc();
    await _writeJson(_modelFile(userId), {
      'version': 4,
      'userId': userId,
      'pipeline': weightedPipelineVersion,
      'model': model.toJson(),
      'threshold': weightedThreshold,
      'trainedAt': trainedAt.toIso8601String(),
      'trainedWithCount': ownSet.examples.length,
      'enrollmentCount': ownSet.enrollment,
      'importedCount': ownSet.imported,
      'loginCount': ownSet.login,
      'availableCount': ownSet.available,
      'skipped': ownSet.skipped,
      'selectedIds': [for (final e in ownSet.examples) e.id],
      'fitCount': weightedEnrollmentCount,
      'trigger': trigger,
    });
    return (await _loadModelInfo(userId))!;
  }

  /// Second factor for a login attempt. Throws [BehaviorFeatureException]
  /// when the attempt has too little sensor data and [StateError] when no
  /// current model exists.
  Future<BehaviorDecision> verifyBehavior(
      String userId, TrialRecord attempt) async {
    final json = await _readModelJson(userId);
    if (json == null) throw StateError('학습된 모델이 없습니다.');
    final model = WeightedClaimantModel.fromJson(
        (json['model'] as Map).cast<String, dynamic>());
    final threshold = (json['threshold'] as num).toDouble();
    double score;
    try {
      score = model.score(weightedFeaturesFromTrial(attempt));
    } on WeightedFeatureException catch (e) {
      throw BehaviorFeatureException(e.message);
    }
    return BehaviorDecision(
        score, threshold, isBehaviorAccepted(score, threshold: threshold));
  }

  Future<Map<String, dynamic>?> _readModelJson(String userId) async {
    final file = _modelFile(userId);
    if (!await file.exists()) return null;
    try {
      final json = await _readJson(file);
      // A model from another pipeline or scaler is treated as untrained.
      if (json['userId'] != userId ||
          json['pipeline'] != weightedPipelineVersion ||
          json['model'] is! Map) {
        return null;
      }
      return json;
    } catch (_) {
      return null;
    }
  }

  Future<BehaviorModelInfo?> _loadModelInfo(String userId) async {
    final json = await _readModelJson(userId);
    if (json == null) return null;
    return BehaviorModelInfo(
      trainedAt: DateTime.parse(json['trainedAt'] as String),
      trainedWithCount: json['trainedWithCount'] as int,
      enrollmentCount: json['enrollmentCount'] as int,
      importedCount: json['importedCount'] as int,
      skipped: json['skipped'] as int,
      threshold: (json['threshold'] as num).toDouble(),
      loginCount: (json['loginCount'] as int?) ?? 0,
      trigger: (json['trigger'] as String?) ?? 'manual',
      availableCount: json['availableCount'] as int?,
    );
  }

  /// Imported trials cropped to [actual_touch_down, actual_touch_up]
  /// (five-second imports are cropped here; converted ones are unchanged).
  Future<List<_ImportedTrial>> _readImportedTrials(Directory batch) async {
    final trialsFile = File('${batch.path}/trials.csv');
    final sensorFile = File('${batch.path}/sensor_events.csv');
    if (!await trialsFile.exists() || !await sensorFile.exists()) {
      return const [];
    }
    final ids = <String>[];
    final nodes = <String, List<double>>{};
    final trialLines = await trialsFile.readAsLines();
    final trialHeader =
        trialLines.isEmpty ? const <String>[] : parseCsvLine(trialLines.first);
    final iNodes = trialHeader.indexOf('node_timestamps');
    for (final line in trialLines.skip(1)) {
      if (!line.contains(',')) continue;
      final f = parseCsvLine(line);
      ids.add(f[0]);
      if (iNodes >= 0 && f.length > iNodes) {
        final text = f[iNodes].replaceAll('[', '').replaceAll(']', '');
        final values = [
          for (final part in text.split(','))
            if (part.trim().isNotEmpty) double.tryParse(part.trim()),
        ];
        if (values.isNotEmpty && values.every((v) => v != null)) {
          nodes[f[0]] = values.cast<double>();
        }
      }
    }
    final bounds = <String, (double, double)>{};
    final metaFile = File('${batch.path}/fixed_window_metadata.csv');
    if (await metaFile.exists()) {
      final lines = await metaFile.readAsLines();
      if (lines.isNotEmpty) {
        final header = parseCsvLine(lines.first);
        final iDown = header.indexOf('actual_touch_down');
        final iUp = header.indexOf('actual_touch_up');
        for (final line in lines.skip(1)) {
          final f = parseCsvLine(line);
          if (iDown < 0 || iUp < 0 || f.length <= max(iDown, iUp)) continue;
          final down = double.tryParse(f[iDown]), up = double.tryParse(f[iUp]);
          if (down != null && up != null) bounds[f[0]] = (down, up);
        }
      }
    }
    final rows = <String, List<SensorRow>>{};
    for (final line in (await sensorFile.readAsLines()).skip(1)) {
      final f = line.split(',');
      if (f.length < 8) continue;
      final values = f.sublist(1, 8).map(double.tryParse).toList();
      if (values.any((v) => v == null)) continue;
      (rows[f[0]] ??= []).add(values.cast<double>());
    }
    final result = <_ImportedTrial>[];
    for (final id in ids) {
      final data = rows[id];
      if (data == null || data.isEmpty) continue;
      final times = data.map((r) => r[0]);
      final (down, up) = bounds[id] ?? (times.reduce(min), times.reduce(max));
      result.add(_ImportedTrial(
          id,
          [
            for (final r in data)
              if (r[0] >= down && r[0] <= up) r
          ],
          nodes[id] ?? const [],
          down,
          up));
    }
    return result;
  }

  Future<List<EnrollmentRecord>> _validRecords(
      String userId, _PatternVerifier verifier) async {
    final session1 = enrollmentSessionId(userId, 1);
    final session2 = enrollmentSessionId(userId, 2);
    final summaries = await storage.loadSummaries();
    final candidates = summaries.where((summary) =>
        summary.participantId == userId &&
        (summary.sessionId == session1 || summary.sessionId == session2));
    final trials = <TrialRecord>[];
    for (final candidate in candidates) {
      try {
        final trial = await storage.loadTrial(candidate.id);
        if (trial != null &&
            trial.participantId == userId &&
            (trial.sessionId == session1 || trial.sessionId == session2) &&
            _enrollmentModes.contains(trial.captureMode) &&
            trial.index >= 1 &&
            trial.index <= 5 &&
            _matches(verifier, trial.actual) &&
            TrialSummary.fromRecord(trial).status == TrialStatus.success) {
          trials.add(trial);
        }
      } catch (_) {
        // A missing or malformed source never contributes to progress.
      }
    }
    trials.sort((a, b) {
      final session = a.sessionId.compareTo(b.sessionId);
      if (session != 0) return session;
      final index = a.index.compareTo(b.index);
      if (index != 0) return index;
      return a.id.compareTo(b.id);
    });
    final result = <EnrollmentRecord>[];
    for (final (session, sessionId) in [(1, session1), (2, session2)]) {
      var expected = 1;
      for (final trial
          in trials.where((trial) => trial.sessionId == sessionId)) {
        if (trial.index != expected) continue;
        result.add(EnrollmentRecord(
          recordId: trial.id,
          sessionIndex: session,
          attemptIndex: expected,
          capturedAt: TrialSummary.fromRecord(trial).createdAt,
          patternStartAt: trial.start,
          patternEndAt: trial.end,
          sensorDataRef: 'records/${trial.id}.json',
          captureMode: trial.captureMode,
        ));
        expected++;
      }
    }
    return result;
  }

  Future<List<String>> _validLoginRecordIds(
      String userId, _PatternVerifier verifier) async {
    final session = loginSessionId(userId);
    final found = <(String, double)>[];
    for (final summary in await storage.loadSummaries()) {
      if (summary.participantId != userId || summary.sessionId != session) {
        continue;
      }
      try {
        final trial = await storage.loadTrial(summary.id);
        if (trial != null &&
            trial.participantId == userId &&
            trial.sessionId == session &&
            (trial.captureMode == TrialRecord.touchBoundedMode ||
                trial.captureMode == TrialRecord.touchCalibratedMode) &&
            _matches(verifier, trial.actual) &&
            TrialSummary.fromRecord(trial).status == TrialStatus.success) {
          found.add((trial.id, trial.start));
        }
      } catch (_) {
        // A missing or malformed source never counts as valid data.
      }
    }
    found.sort((a, b) => a.$2.compareTo(b.$2));
    return [for (final f in found) f.$1];
  }

  List<int> _validPattern(List<int> nodes) {
    final pattern = PatternRules.normalize(nodes);
    if (pattern.length < 3 ||
        pattern.length > 9 ||
        pattern.toSet().length != pattern.length) {
      throw ArgumentError.value(nodes, 'nodes', '3~9개 점으로 패턴을 그려 주세요.');
    }
    return pattern;
  }

  String _digest(List<int> salt, List<int> nodes) =>
      Hmac(sha256, salt).convert(utf8.encode(nodes.join('-'))).toString();

  bool _matches(_PatternVerifier verifier, List<int> nodes) {
    List<int> pattern;
    try {
      pattern = _validPattern(nodes);
    } on ArgumentError {
      return false;
    }
    final actual = _digest(verifier.salt, pattern);
    if (actual.length != verifier.digest.length) return false;
    var diff = 0;
    for (var i = 0; i < actual.length; i++) {
      diff |= actual.codeUnitAt(i) ^ verifier.digest.codeUnitAt(i);
    }
    return diff == 0;
  }

  Future<_PatternVerifier?> _loadVerifier(String userId) async {
    final file = _verifierFile(userId);
    if (!await file.exists()) return null;
    final json = await _readJson(file);
    if (json['version'] != 1 ||
        json['salt'] is! String ||
        json['digest'] is! String) {
      throw const FormatException('Invalid pattern verifier');
    }
    return _PatternVerifier(
      base64Decode(json['salt'] as String),
      json['digest'] as String,
      json['confirmedAt'] is String
          ? DateTime.parse(json['confirmedAt'] as String)
          : null,
    );
  }

  Future<Map<String, dynamic>> _readJson(File file) async =>
      Map<String, dynamic>.from(jsonDecode(await file.readAsString()));

  Future<void> _writeJson(File file, Map<String, dynamic> json) async {
    await file.parent.create(recursive: true);
    final random = Random.secure().nextInt(0x7fffffff);
    final temp = File(
        '${file.path}.${DateTime.now().microsecondsSinceEpoch}.$random.tmp');
    try {
      await temp.writeAsString(jsonEncode(json), flush: true);
      await temp.rename(file.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }
}

class TrainingImportResult {
  final String sourceName;
  final int imported, patternMismatch, duplicate, missingSensor;

  /// Set when this import brought valid data to [validDataTarget] and the
  /// model was trained automatically.
  final BehaviorModelInfo? autoTrained;
  final String? autoTrainError;
  const TrainingImportResult({
    required this.sourceName,
    required this.imported,
    required this.patternMismatch,
    required this.duplicate,
    required this.missingSensor,
    this.autoTrained,
    this.autoTrainError,
  });

  TrainingImportResult withAutoTraining(
          BehaviorModelInfo? model, String? error) =>
      TrainingImportResult(
        sourceName: sourceName,
        imported: imported,
        patternMismatch: patternMismatch,
        duplicate: duplicate,
        missingSensor: missingSensor,
        autoTrained: model,
        autoTrainError: error,
      );
}

/// Minimum legacy enrollment count retained for compatibility checks.
const minTrainingSamples = 10;

class TrainingSet {
  /// The first [validDataTarget] usable samples in arrival order.
  final List<BehaviorSample> vectors;

  /// How many of [vectors] come from each source.
  final int enrollment, imported, skipped, login;

  /// Usable valid data before the [validDataTarget] cap.
  final int available;
  final List<TrainingExample> examples;
  const TrainingSet(this.vectors, this.enrollment, this.imported, this.skipped,
      {this.login = 0, int? available, this.examples = const []})
      : available = available ?? vectors.length;
}

class TrainingExample {
  final String id, source;
  final List<SensorRow> rows;
  final List<double> nodes;
  final double down, up;
  final BehaviorSample sample;
  const TrainingExample(this.id, this.source, this.rows, this.nodes, this.down,
      this.up, this.sample);
}

class _TrainingEntry {
  final DateTime arrival;
  final int order;
  final String source;
  final Future<TrainingExample?> Function() load;
  const _TrainingEntry(this.arrival, this.order, this.source, this.load);
}

class LoginCaptureResult {
  /// Whether the login capture was stored as training data.
  final bool stored;

  /// Valid data count after this call.
  final int validDataCount;

  /// Set when this capture reached [validDataTarget] and the model was
  /// trained automatically.
  final BehaviorModelInfo? autoTrained;
  final String? autoTrainError;
  const LoginCaptureResult({
    required this.stored,
    required this.validDataCount,
    this.autoTrained,
    this.autoTrainError,
  });
}

class BehaviorModelInfo {
  final DateTime trainedAt;
  final int trainedWithCount, enrollmentCount, importedCount, skipped;
  final double threshold;

  /// Stored login captures used for training.
  final int loginCount;

  /// 'manual' (profile button) or 'auto' (valid data reached 40).
  final String trigger;

  /// Usable valid data when trained; only the first [validDataTarget] of it
  /// were used ([trainedWithCount]).
  final int availableCount;
  const BehaviorModelInfo({
    required this.trainedAt,
    required this.trainedWithCount,
    required this.enrollmentCount,
    required this.importedCount,
    required this.skipped,
    required this.threshold,
    this.loginCount = 0,
    this.trigger = 'manual',
    int? availableCount,
  }) : availableCount = availableCount ?? trainedWithCount;
}

class BehaviorDecision {
  final double score, threshold;
  final bool accepted;
  const BehaviorDecision(this.score, this.threshold, this.accepted);
}

class _ImportedTrial {
  final String id;
  final List<SensorRow> rows;
  final List<double> nodes;
  final double down, up;
  const _ImportedTrial(this.id, this.rows, this.nodes, this.down, this.up);
}

class _ImportBatch {
  final List<String> trialIds;
  const _ImportBatch(this.trialIds);
}

class _PatternVerifier {
  final List<int> salt;
  final String digest;
  final DateTime? confirmedAt;
  const _PatternVerifier(this.salt, this.digest, this.confirmedAt);
}
