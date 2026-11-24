import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';

import 'data_management.dart';
import 'device_identity.dart';
import 'export_filename.dart';
import 'model.dart';

const trialHeader =
    'trial_id,participant_id,pattern,node_timestamps,device_id,hand,posture';
const sensorHeader = 'trial_id,timestamp,ax,ay,az,gx,gy,gz';
const touchHeader =
    'trial_id,timestamp,event_type,touch_x_norm,touch_y_norm,node_id,node_source,timestamp_estimated';
const rawHeader = 'trial_id,timestamp,sensor_type,x,y,z';
const diagnosticHeader =
    'trial_id,session_id,trial_index,participant_id,target_pattern,actual_pattern,pattern_match,valid_input,trial_result,ml_exported,exclude_reason,requested_accel_hz,requested_gyro_hz,actual_accel_hz,actual_gyro_hz,raw_accel_count,raw_gyro_count,ml_sensor_row_count,missing_6axis_count,largest_sensor_gap_ms,sync_quality,device_model,platform,os_version,device_held,holding_hand,hit_radius_norm,clock_offset_error_ms,node_timing_estimated_count,app_version';

class ExportArtifact {
  final File zip;
  final String exportId;
  final Set<String> targetPatterns;
  const ExportArtifact(this.zip, this.exportId, this.targetPatterns);
}

String csvCell(Object? value) {
  final text = value?.toString() ?? '';
  if (text.contains(',') ||
      text.contains('"') ||
      text.contains('\n') ||
      text.contains('\r')) {
    return '"${text.replaceAll('"', '""')}"';
  }
  return text;
}

String csvRow(Iterable<Object?> cells) => cells.map(csvCell).join(',');
String seconds(double value) => value.toStringAsFixed(9);
String number(double value) => value.toStringAsPrecision(12);

class SessionStorage {
  final Directory root;
  Future<DeviceIdentity>? _identityFuture;
  SessionStorage(this.root);
  Directory get records => Directory('${root.path}/records');
  Directory get index => Directory('${root.path}/trial_index');
  Directory get exports => Directory('${root.path}/exports');
  File get activeFile => File('${root.path}/active.txt');
  File get settingsFile => File('${root.path}/settings.json');

  Future<Map<String, dynamic>> loadSettings() async {
    if (!await settingsFile.exists()) return {};
    return Map<String, dynamic>.from(
      jsonDecode(await settingsFile.readAsString()),
    );
  }

  Future<void> saveSettings(Map<String, dynamic> values) async {
    await root.create(recursive: true);
    final temp = File('${settingsFile.path}.tmp');
    await temp.writeAsString(jsonEncode(values), flush: true);
    if (await settingsFile.exists()) await settingsFile.delete();
    await temp.rename(settingsFile.path);
  }

  Future<DeviceIdentity> ensureDeviceIdentity() =>
      _identityFuture ??= _ensureDeviceIdentity();

  Future<DeviceIdentity> _ensureDeviceIdentity() async {
    final settings = await loadSettings();
    final existing = settings['device_uid'];
    if (existing is String) return DeviceIdentity(existing);
    if (existing != null) throw StateError('Invalid stored device UID');
    final identity = DeviceIdentity(uuidV4());
    await saveSettings({...settings, 'device_uid': identity.uid});
    return identity;
  }

  Future<List<TrialRecord>> loadTrials() async {
    if (!await records.exists()) return [];
    final files = await records
        .list()
        .where((e) => e is File && e.path.endsWith('.json'))
        .cast<File>()
        .toList();
    files.sort((a, b) => a.path.compareTo(b.path));
    final result = <TrialRecord>[];
    for (final file in files) {
      result.add(
        TrialRecord.fromJson(
          Map<String, dynamic>.from(jsonDecode(await file.readAsString())),
        ),
      );
    }
    return result;
  }

  Future<void> saveTrial(TrialRecord trial) async {
    await records.create(recursive: true);
    final file = File('${records.path}/${trial.id}.json');
    if (!await file.exists()) {
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(jsonEncode(trial.toJson()), flush: true);
      await temp.rename(file.path);
    }
    await _writeIndex(TrialSummary.fromRecord(trial));
  }

  Future<void> _writeIndex(TrialSummary summary) async {
    await index.create(recursive: true);
    final file = File('${index.path}/${summary.id}.json');
    final temp = File('${file.path}.tmp');
    await temp.writeAsString(jsonEncode(summary.toJson()), flush: true);
    if (await file.exists()) await file.delete();
    await temp.rename(file.path);
  }

  Future<TrialRecord?> loadTrial(String id) async {
    if (!RegExp(r'^T[\w-]+$').hasMatch(id)) return null;
    final file = File('${records.path}/$id.json');
    if (!await file.exists()) return null;
    return TrialRecord.fromJson(
      Map<String, dynamic>.from(jsonDecode(await file.readAsString())),
    );
  }

  Future<List<TrialSummary>> loadSummaries() async {
    await index.create(recursive: true);
    if (await records.exists()) {
      await for (final entry in records.list()) {
        if (entry is! File || !entry.path.endsWith('.json')) continue;
        final id = entry.uri.pathSegments.last.replaceAll('.json', '');
        if (!await File('${index.path}/$id.json').exists()) {
          try {
            final t = await loadTrial(id);
            if (t != null) await _writeIndex(TrialSummary.fromRecord(t));
          } catch (_) {
            await _writeIndex(TrialSummary.legacyUnknown(id));
          }
        }
      }
    }
    final result = <TrialSummary>[];
    await for (final entry in index.list()) {
      if (entry is File && entry.path.endsWith('.json')) {
        result.add(
          TrialSummary.fromJson(
            Map<String, dynamic>.from(jsonDecode(await entry.readAsString())),
          ),
        );
      }
    }
    // v1.1 always wrote JSON, but retain orphaned old CSV entries as review.
    final known = result.map((s) => s.id).toSet();
    final old = await activeExport();
    if (old != null) {
      for (final name in ['trial_diagnostics.csv', 'trials.csv']) {
        final file = File('${old.path}/$name');
        if (!await file.exists()) continue;
        final lines = await file.readAsLines();
        for (final line in lines.skip(1)) {
          if (line.isEmpty) continue;
          final fields = _csvFields(line);
          if (fields.isEmpty ||
              fields.first.isEmpty ||
              !known.add(fields.first)) {
            continue;
          }
          result.add(
            name == 'trial_diagnostics.csv' && fields.length >= 6
                ? TrialSummary.legacyUnknown(
                    fields[0],
                    target: fields[4],
                    actual: fields[5],
                    participantId: fields.length > 3 ? fields[3] : '',
                  )
                : TrialSummary.legacyUnknown(
                    fields[0],
                    actual: fields.length > 2 ? fields[2] : '',
                    participantId: fields.length > 1 ? fields[1] : '',
                  ),
          );
        }
      }
    }
    result.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return result;
  }

  Future<Directory?> activeExport() async {
    if (!await activeFile.exists()) return null;
    final name = (await activeFile.readAsString()).trim();
    final dir = Directory('${exports.path}/$name');
    return await dir.exists() ? dir : null;
  }

  Future<Directory> rebuild() async {
    final trials = await loadTrials();
    await exports.create(recursive: true);
    final generation = 'g${DateTime.now().microsecondsSinceEpoch}';
    final temp = Directory('${exports.path}/$generation.tmp');
    await temp.create(recursive: true);
    final trialRows = <String>[trialHeader];
    final sensorRows = <String>[sensorHeader];
    final touchRows = <String>[touchHeader];
    final rawRows = <String>[rawHeader];
    final diagnosticRows = <String>[diagnosticHeader];
    final seen = <String>{};
    for (final t in trials) {
      if (!seen.add(t.id)) throw StateError('Duplicate trial ID: ${t.id}');
      final q = assess(t);
      final accel = t.sensors.where((s) => s.type == 'ACCEL').toList();
      final gyro = t.sensors.where((s) => s.type == 'GYRO').toList();
      if (q.eligible && t.matched) {
        trialRows.add(
          csvRow([
            t.id,
            t.participantId,
            t.actual.join('-'),
            '[${t.visits.map((v) => seconds(v.time)).join(',')}]',
            t.deviceId,
            t.hand,
            t.posture,
          ]),
        );
        for (final r in q.joined.rows) {
          sensorRows.add(
            csvRow([
              t.id,
              seconds(r.time),
              number(r.ax),
              number(r.ay),
              number(r.az),
              number(r.gx),
              number(r.gy),
              number(r.gz),
            ]),
          );
        }
      }
      final orderedTouches = <(double, int, String)>[];
      for (final e in t.touches) {
        orderedTouches.add((
          e.time,
          0,
          csvRow([
            t.id,
            seconds(e.time),
            e.type,
            number(e.x),
            number(e.y),
            '',
            '',
            '',
          ]),
        ));
      }
      for (final v in t.visits) {
        final point = _nodePoint(v.node);
        orderedTouches.add((
          v.time,
          1,
          csvRow([
            t.id,
            seconds(v.time),
            'NODE_HIT',
            number(v.x ?? point.$1),
            number(v.y ?? point.$2),
            v.node,
            v.source,
            v.estimated,
          ]),
        ));
      }
      orderedTouches.sort((a, b) {
        final c = a.$1.compareTo(b.$1);
        return c != 0 ? c : a.$2.compareTo(b.$2);
      });
      touchRows.addAll(orderedTouches.map((e) => e.$3));
      for (final s in t.sensors) {
        rawRows.add(
          csvRow([
            t.id,
            seconds(s.time),
            s.type,
            number(s.x),
            number(s.y),
            number(s.z),
          ]),
        );
      }
      final trialAccel =
          accel.where((s) => s.time >= t.start && s.time <= t.end).length;
      final trialGyro =
          gyro.where((s) => s.time >= t.start && s.time <= t.end).length;
      final aHz = t.end > t.start ? trialAccel / (t.end - t.start) : 0.0;
      final gHz = t.end > t.start ? trialGyro / (t.end - t.start) : 0.0;
      diagnosticRows.add(
        csvRow([
          t.id,
          t.sessionId,
          t.index,
          t.participantId,
          t.target.join('-'),
          t.actual.join('-'),
          t.matched,
          q.result == 'matched' || q.result == 'mismatched',
          q.result,
          q.eligible,
          q.reason,
          100,
          100,
          number(aHz),
          number(gHz),
          accel.length,
          gyro.length,
          q.eligible ? q.joined.rows.length : 0,
          q.joined.missing,
          number(q.joined.largestAgeMs),
          q.eligible ? 'ok' : 'rejected',
          t.model,
          t.platform,
          t.osVersion,
          'handheld',
          t.holdingHand,
          t.hitRadiusNorm,
          number(t.clockErrorMs),
          t.visits.where((v) => v.estimated).length,
          '1.1.0',
        ]),
      );
    }
    final contents = {
      'trials.csv': trialRows,
      'sensor_events.csv': sensorRows,
      'touch_events.csv': touchRows,
      'sensor_raw_events.csv': rawRows,
      'trial_diagnostics.csv': diagnosticRows,
    };
    for (final entry in contents.entries) {
      await File('${temp.path}/${entry.key}')
          .writeAsString('${entry.value.join('\r\n')}\r\n', flush: true);
    }
    await File('${temp.path}/README.txt').writeAsString(_readme, flush: true);
    // A complete generation is made visible only after every file has been flushed.
    final finalDir = await temp.rename('${exports.path}/$generation');
    final pointer = File('${activeFile.path}.tmp');
    await pointer.writeAsString(generation, flush: true);
    if (await activeFile.exists()) await activeFile.delete();
    await pointer.rename(activeFile.path);
    return finalDir;
  }

  Future<File> exportSelected(
    Set<String> ids, {
    required bool diagnostics,
    bool legacy = false,
    bool splitByPattern = false,
    int excludedFailed = 0,
    int excludedReview = 0,
    bool Function()? cancelled,
  }) async =>
      (await createExportSelected(
        ids,
        diagnostics: diagnostics,
        legacy: legacy,
        splitByPattern: splitByPattern,
        excludedFailed: excludedFailed,
        excludedReview: excludedReview,
        cancelled: cancelled,
      ))
          .zip;

  Future<ExportArtifact> createExportSelected(
    Set<String> ids, {
    required bool diagnostics,
    bool legacy = false,
    bool splitByPattern = false,
    int excludedFailed = 0,
    int excludedReview = 0,
    bool Function()? cancelled,
  }) async {
    if (ids.isEmpty) throw StateError('내보낼 기록이 없습니다.');
    final summaries = {for (final s in await loadSummaries()) s.id: s};
    if (ids.any((id) => !summaries.containsKey(id))) {
      throw StateError('기록 ID가 없습니다.');
    }
    final chosen = ids.map((id) => summaries[id]!).toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    if (chosen.any(
      (s) => diagnostics
          ? s.status == TrialStatus.success
          : legacy
              ? !s.legacySuccess
              : !s.fixedWindowSuccess,
    )) {
      throw StateError('선택한 기록의 상태가 내보내기 종류와 다릅니다.');
    }
    if (chosen.any((s) => s.source != 'json_v1.1')) {
      throw StateError('원본이 없는 기록은 내보낼 수 없습니다.');
    }
    final identity = await ensureDeviceIdentity();
    final settings = await loadSettings();
    final label = settings['device']?.toString() ?? 'device';
    final createdAt = DateTime.now().toUtc();
    final exportId = uuidV4().replaceAll('-', '');
    final participantIds = chosen.map((s) => s.participantId).toSet();
    final targetPatterns = chosen.map((s) => s.targetPattern).toSet();
    final filename = exportFilename(
      identity,
      createdAt,
      exportId,
      participantId: participantIds.length == 1
          ? participantIds.single
          : 'multiple-participants',
      patternId:
          targetPatterns.length == 1 ? targetPatterns.single : 'multi-pattern',
    );
    final zip = File('${exports.path}/$filename');
    final temp = Directory('${exports.path}/export_$exportId.tmp');
    if (await zip.exists() || await temp.exists()) {
      throw StateError('Export ID collision');
    }
    await temp.create(recursive: true);
    try {
      if (diagnostics) {
        await _writeDiagnostics(temp, chosen, cancelled);
      } else if (splitByPattern) {
        final groups = groupTrials(chosen);
        for (final group in groups.entries) {
          if (cancelled?.call() == true) throw const ExportCancelled();
          final path = group.key;
          if (!RegExp(r'^[1-9](?:-[1-9]){2,8}$').hasMatch(path)) {
            throw StateError('패턴 경로가 올바르지 않습니다.');
          }
          final dir = Directory('${temp.path}/patterns/$path');
          await dir.create(recursive: true);
          await _writeSuccess(dir, group.value, cancelled, legacy: legacy);
        }
      } else {
        await _writeSuccess(temp, chosen, cancelled, legacy: legacy);
      }
      await _writeWindowMetadata(temp, chosen);
      await File('${temp.path}/export_manifest.csv').writeAsString(
        'export_id,export_time_utc,mode,selected_pattern_count,exported_trial_count,excluded_failed_count,excluded_review_count,schema_version,capture_mode,device_label,device_uid,device_tag,export_filename,created_at_utc\r\n'
        '${csvRow([
              exportId,
              createdAt.toIso8601String(),
              diagnostics
                  ? 'diagnostics'
                  : legacy
                      ? 'legacy_explicit'
                      : splitByPattern
                          ? 'by_pattern'
                          : 'success',
              chosen.map((s) => s.targetPattern).toSet().length,
              chosen.length,
              excludedFailed,
              excludedReview,
              diagnostics || legacy ? '1.3.2' : '1.4.0',
              diagnostics
                  ? 'diagnostic'
                  : legacy
                      ? chosen.map((s) => s.captureMode).toSet().join('|')
                      : TrialRecord.fixedWindow5Mode,
              label,
              identity.uid,
              identity.tag,
              filename,
              createdAt.toIso8601String()
            ])}\r\n',
        flush: true,
      );
      await File('${temp.path}/README.txt').writeAsString(
        diagnostics
            ? '진단 데이터입니다. 학습용 trials.csv와 sensor_events.csv는 포함되지 않습니다.\n원본 센서가 없는 입력은 sensor_raw_events.csv에 측정 행이 없습니다. 임의 측정값은 생성하지 않았습니다.\n'
            : legacy
                ? '명시적으로 선택한 구버전 데이터입니다. 각 기록의 capture_mode와 고정창 메타데이터를 확인하고 새 5초 창 데이터와 합치지 마세요.\n'
                : splitByPattern
                    ? '각 patterns/ 폴더의 CSV 두 개를 따로 학습 코드에 입력하세요.\n'
                    : '루트의 CSV 두 개는 버튼 기준 고정 5초 창의 학습 입력입니다. node_timestamps는 정답 라벨이며 전체 5초 추론 평가의 입력이나 절단 경계로 사용하지 마세요.\n',
        flush: true,
      );
      if (cancelled?.call() == true) throw const ExportCancelled();
      final encoder = ZipFileEncoder()..create(zip.path);
      try {
        await for (final entity in temp.list(recursive: true)) {
          if (cancelled?.call() == true) throw const ExportCancelled();
          if (entity is File) {
            final relative = entity.path
                .substring(temp.path.length + 1)
                .replaceAll('\\', '/');
            await encoder.addFile(entity, relative);
          }
        }
        await encoder.close();
      } catch (_) {
        await encoder.close();
        if (await zip.exists()) await zip.delete();
        rethrow;
      }
      return ExportArtifact(
        zip,
        exportId,
        chosen.map((s) => s.targetPattern).toSet(),
      );
    } finally {
      for (var attempt = 0; attempt < 10 && await temp.exists(); attempt++) {
        try {
          await temp.delete(recursive: true);
        } on FileSystemException {
          if (attempt == 9) rethrow;
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      }
    }
  }

  Future<void> _writeSuccess(
    Directory dir,
    List<TrialSummary> selected,
    bool Function()? cancelled, {
    bool legacy = false,
  }) async {
    final trials = File('${dir.path}/trials.csv').openWrite();
    final sensors = File('${dir.path}/sensor_events.csv').openWrite();
    trials.writeln(trialHeader);
    sensors.writeln(sensorHeader);
    try {
      for (final summary in selected) {
        if (cancelled?.call() == true) throw const ExportCancelled();
        final t = await loadTrial(summary.id);
        if (t == null) throw StateError('원본 기록 누락: ${summary.id}');
        final q = assess(t);
        if (legacy
            ? t.captureMode != TrialRecord.legacyMode &&
                t.captureMode != TrialRecord.fixedWindowMode
            : t.captureMode != TrialRecord.fixedWindow5Mode) {
          throw StateError('수집 모드가 다른 기록: ${t.id}');
        }
        if (!t.matched ||
            !q.eligible ||
            q.joined.rows.isEmpty ||
            t.visits.length != t.actual.length) {
          throw StateError('학습 적합성 검증 실패: ${t.id}');
        }
        var previous = double.negativeInfinity;
        for (final visit in t.visits) {
          if (visit.time <= previous) throw StateError('노드 시각 역전: ${t.id}');
          previous = visit.time;
        }
        trials.writeln(
          csvRow([
            t.id,
            t.participantId,
            t.actual.join('-'),
            '[${t.visits.map((v) => seconds(v.time)).join(',')}]',
            t.deviceId,
            t.hand,
            t.posture,
          ]),
        );
        for (final row in q.joined.rows) {
          if (t.captureMode != TrialRecord.legacyMode &&
              (row.time < t.captureStartMonotonic! ||
                  row.time >= t.captureEndMonotonic!)) {
            throw StateError('고정창 밖 센서 행: ${t.id}');
          }
          sensors.writeln(
            csvRow([
              t.id,
              seconds(row.time),
              number(row.ax),
              number(row.ay),
              number(row.az),
              number(row.gx),
              number(row.gy),
              number(row.gz),
            ]),
          );
        }
      }
    } finally {
      await trials.close();
      await sensors.close();
    }
  }

  Future<void> _writeWindowMetadata(
    Directory dir,
    List<TrialSummary> selected,
  ) async {
    final output = File('${dir.path}/fixed_window_metadata.csv').openWrite();
    output.writeln(
      'trial_id,capture_mode,button_t0_monotonic,capture_start_monotonic,capture_end_monotonic,actual_touch_down,actual_touch_up,pre_delay_sec,window_duration_sec,window_completeness,window_error,button_dispatch_delay_ms,deadline_error_ms',
    );
    try {
      for (final summary in selected) {
        final t = await loadTrial(summary.id);
        if (t == null) throw StateError('원본 기록 누락: ${summary.id}');
        output.writeln(
          csvRow([
            t.id,
            t.captureMode,
            t.buttonT0Monotonic,
            t.captureStartMonotonic,
            t.captureEndMonotonic,
            t.actualTouchDown,
            t.actualTouchUp,
            t.captureMode == TrialRecord.fixedWindow5Mode
                ? 0.0 : t.captureMode == TrialRecord.fixedWindowMode ? 0.5 : '',
            t.captureMode == TrialRecord.fixedWindow5Mode
                ? 5.0 : t.captureMode == TrialRecord.fixedWindowMode ? 4.0 : '',
            t.windowComplete,
            t.windowError,
            t.buttonDispatchDelayMs,
            t.deadlineErrorMs,
          ]),
        );
      }
    } finally {
      await output.close();
    }
  }

  Future<void> _writeDiagnostics(
    Directory dir,
    List<TrialSummary> selected,
    bool Function()? cancelled,
  ) async {
    final diag = File('${dir.path}/failed_trial_diagnostics.csv').openWrite();
    final touch = File('${dir.path}/touch_events.csv').openWrite();
    final raw = File('${dir.path}/sensor_raw_events.csv').openWrite();
    diag.writeln(diagnosticHeader);
    touch.writeln(touchHeader);
    raw.writeln(rawHeader);
    try {
      for (final summary in selected) {
        if (cancelled?.call() == true) throw const ExportCancelled();
        final t = await loadTrial(summary.id);
        if (t == null) throw StateError('원본 기록 누락: ${summary.id}');
        final q = assess(t);
        final accel = t.sensors.where((s) => s.type == 'ACCEL').length;
        final gyro = t.sensors.where((s) => s.type == 'GYRO').length;
        diag.writeln(
          csvRow([
            t.id,
            t.sessionId,
            t.index,
            t.participantId,
            t.target.join('-'),
            t.actual.join('-'),
            t.matched,
            q.result == 'matched' || q.result == 'mismatched',
            q.result,
            false,
            summary.reason,
            100,
            100,
            '',
            '',
            accel,
            gyro,
            0,
            q.joined.missing,
            number(q.joined.largestAgeMs),
            'rejected',
            t.model,
            t.platform,
            t.osVersion,
            'handheld',
            t.holdingHand,
            t.hitRadiusNorm,
            number(t.clockErrorMs),
            t.visits.where((v) => v.estimated).length,
            t.captureMode == TrialRecord.fixedWindow5Mode ? '1.4.0' : '1.3.1',
          ]),
        );
        for (final e in t.touches) {
          touch.writeln(
            csvRow([
              t.id,
              seconds(e.time),
              e.type,
              number(e.x),
              number(e.y),
              '',
              '',
              '',
            ]),
          );
        }
        for (final v in t.visits) {
          final point = _nodePoint(v.node);
          touch.writeln(
            csvRow([
              t.id,
              seconds(v.time),
              'NODE_HIT',
              number(v.x ?? point.$1),
              number(v.y ?? point.$2),
              v.node,
              v.source,
              v.estimated,
            ]),
          );
        }
        for (final s in t.sensors) {
          raw.writeln(
            csvRow([
              t.id,
              seconds(s.time),
              s.type,
              number(s.x),
              number(s.y),
              number(s.z),
            ]),
          );
        }
      }
    } finally {
      await diag.close();
      await touch.close();
      await raw.close();
    }
  }
}

class ExportCancelled implements Exception {
  const ExportCancelled();
}

List<String> _csvFields(String line) {
  final cells = <String>[];
  final cell = StringBuffer();
  var quoted = false;
  for (var i = 0; i < line.length; i++) {
    final ch = line[i];
    if (ch == '"') {
      if (quoted && i + 1 < line.length && line[i + 1] == '"') {
        cell.write('"');
        i++;
      } else {
        quoted = !quoted;
      }
    } else if (ch == ',' && !quoted) {
      cells.add(cell.toString());
      cell.clear();
    } else {
      cell.write(ch);
    }
  }
  cells.add(cell.toString());
  return cells;
}

(double, double) _nodePoint(int node) =>
    (((node - 1) % 3 + 1) / 4, ((node - 1) ~/ 3 + 1) / 4);

const _readme = '''Pattern Sensor Collector 1.1\n
Research-only pattern and local sensor dataset. Do not enter an actual device unlock secret.\n
trials.csv and sensor_events.csv are the two ML input files. Timestamps are seconds from
the device monotonic boot clock. They are not wall time and reset after reboot.
Accelerometer axes are m/s^2 including gravity; gyroscope axes are rad/s.
Sensor rows use the union of asynchronous native event timestamps with as-of carry-forward
of the latest sample from each sensor (maximum age 50 ms). A row is not a simultaneous
measurement of six axes. Two nominal 100 Hz sensors can produce about 200 rows/s.
Rows without both recent samples are excluded. A trial needs at least 95% valid rows and
at least three rows per adjacent-node segment to enter the ML files.
touch_events.csv includes un-clamped normalized coordinates on the board. Node arrival is
first entry into the per-trial hit radius in trial_diagnostics.csv (hit_radius_norm);
interpolated crossing and Android intermediate
node timing are marked estimated. Raw native sensor events are in sensor_raw_events.csv,
including samples collected while armed before the first touch and just after release.
Failures and excluded trials remain in trial_diagnostics.csv and the JSON source records.
The target pattern is diagnostic only; the trials.csv pattern is the actual input.
The companion pattern_ml.py is not included, so its prepare command cannot be verified here.
''';
