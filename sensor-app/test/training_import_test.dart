import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pattern_sensor_collector/enrollment_repository.dart';
import 'package:pattern_sensor_collector/storage.dart';
import 'package:pattern_sensor_collector/training_import.dart';

import 'enrollment_repository_test.dart' show capture;

/// Builds a ZIP shaped like a research-collector "success" export.
Uint8List exportZip(Map<String, String> trialPatterns,
    {bool includeTrials = true, String participant = 'A'}) {
  final trials = StringBuffer(
      'trial_id,participant_id,pattern,node_timestamps,device_id,hand,posture\r\n');
  final sensors = StringBuffer('trial_id,timestamp,ax,ay,az,gx,gy,gz\r\n');
  final meta = StringBuffer(
      'trial_id,capture_mode,button_t0_monotonic,capture_start_monotonic\r\n');
  trialPatterns.forEach((id, pattern) {
    trials.write('$id,$participant,$pattern,"[1.0,1.5,2.0]",C,right,seated\r\n');
    for (var i = 0; i < 3; i++) {
      sensors.write('$id,${1 + i * 0.005},1.5,-0.3,-9.2,0.1,0.09,0.01\r\n');
    }
    meta.write('$id,fixed_window_5s_v1,1.0,1.0\r\n');
  });
  final archive = Archive();
  void add(String name, String text) {
    final bytes = utf8.encode(text);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  if (includeTrials) add('trials.csv', trials.toString());
  add('sensor_events.csv', sensors.toString());
  add('fixed_window_metadata.csv', meta.toString());
  add('export_manifest.csv', 'export_id,mode\r\nabc123,success\r\n');
  add('README.txt', 'test');
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

Future<(Directory, EnrollmentRepository)> _setup() async {
  final root = await Directory.systemTemp.createTemp('training_import_');
  addTearDown(() => root.delete(recursive: true));
  final repository = EnrollmentRepository(SessionStorage(root));
  await repository.createUser(userId: 'user001', displayName: '사용자 A');
  await repository.confirmPattern('user001', [1, 4, 8, 6, 3]);
  return (root, repository);
}

void main() {
  test('only trials matching the registered pattern are imported unchanged',
      () async {
    final (root, repository) = await _setup();
    final result = await repository.importTrainingZip(
      'user001',
      exportZip({
        'T1794485292399205_a29e61': '1-4-8-6-3',
        'T1794485304006593_455fad': '1-4-8-6-3',
        'T1794485310000000_000001': '2-5-8',
      }),
      sourceName: 'A_test.zip',
    );
    expect(result.imported, 2);
    expect(result.patternMismatch, 1);

    final profile = (await repository.getUser('user001'))!;
    expect(profile.importedTrialCount, 2);
    expect(profile.importBatchCount, 1);
    expect(profile.totalCount, 0, reason: 'imports never count as enrollment');

    final batch = (await Directory('${root.path}/imports')
            .list(recursive: true)
            .where((e) => e is Directory && !e.path.endsWith('.tmp'))
            .cast<Directory>()
            .toList())
        .firstWhere((d) => File('${d.path}/import.json').existsSync());
    final trials = await File('${batch.path}/trials.csv').readAsString();
    expect(trials, contains('T1794485292399205_a29e61,A,1-4-8-6-3,"[1.0,1.5,2.0]"'));
    expect(trials, isNot(contains('2-5-8')));
    final sensors = await File('${batch.path}/sensor_events.csv').readAsString();
    expect(sensors, contains('T1794485292399205_a29e61,1.0,1.5,-0.3,-9.2'));
    expect(sensors, isNot(contains('T1794485310000000_000001')));
    final meta = jsonDecode(
        await File('${batch.path}/import.json').readAsString()) as Map;
    expect(meta['source'], 'IMPORT');
    expect(meta['sourceFileName'], 'A_test.zip');
    expect(meta['sourceParticipantIds'], ['A']);
  });

  test('re-importing the same trials is skipped as duplicate', () async {
    final (_, repository) = await _setup();
    final zip = exportZip({'T1794485292399205_a29e61': '1-4-8-6-3'});
    await repository.importTrainingZip('user001', zip, sourceName: 'a.zip');
    final again =
        await repository.importTrainingZip('user001', zip, sourceName: 'a.zip');
    expect(again.imported, 0);
    expect(again.duplicate, 1);
    expect((await repository.getUser('user001'))!.importBatchCount, 1);
  });

  test('archives that are not collector exports are rejected', () async {
    final (_, repository) = await _setup();
    await expectLater(
      repository.importTrainingZip(
          'user001',
          exportZip({'T1794485292399205_a29e61': '1-4-8-6-3'},
              includeTrials: false),
          sourceName: 'bad.zip'),
      throwsA(isA<ImportFormatException>()),
    );
    await expectLater(
      repository.importTrainingZip(
          'user001', Uint8List.fromList([1, 2, 3]), sourceName: 'x.zip'),
      throwsA(isA<ImportFormatException>()),
    );
  });

  test('deleting a user removes profile, verifier, records and imports',
      () async {
    final root = await Directory.systemTemp.createTemp('delete_user_');
    addTearDown(() => root.delete(recursive: true));
    final storage = SessionStorage(root);
    final repository = EnrollmentRepository(storage);
    await repository.createUser(userId: 'user001', displayName: '사용자 A');
    await repository.confirmPattern('user001', [1, 2, 3]);
    await repository.createUser(userId: 'user002', displayName: '사용자 B');
    await repository.confirmPattern('user002', [1, 2, 3]);
    final saved =
        await repository.saveCapture('user001', 1, capture('user001', 1, 1));
    final recordId = saved.records.single.recordId;
    await repository.importTrainingZip(
        'user001', exportZip({'T1794485292399205_a29e61': '1-2-3'}),
        sourceName: 'a.zip');
    final other =
        await repository.saveCapture(
        'user002', 1, capture('user002', 1, 1, idSalt: 1));

    await repository.deleteUser('user001');

    expect(await repository.getUser('user001'), isNull);
    expect(await storage.loadTrial(recordId), isNull);
    expect(File('${storage.index.path}/$recordId.json').existsSync(), isFalse);
    expect(
        Directory('${root.path}/enrollment/verifiers')
            .listSync()
            .length,
        1);
    final imports = Directory('${root.path}/imports');
    expect(imports.existsSync() ? imports.listSync() : const [], isEmpty);
    // Other users are untouched.
    final remaining = (await repository.getUser('user002'))!;
    expect(remaining.records.single.recordId, other.records.single.recordId);
    expect((await repository.getUsers()).map((u) => u.userId), ['user002']);
    // A recreated user with the same ID starts clean.
    final again =
        await repository.createUser(userId: 'user001', displayName: '새 사용자');
    expect(again.totalCount, 0);
    expect(again.importedTrialCount, 0);
    expect(again.hasPattern, isFalse);
  });

  test('csv parser handles quoted node timestamps', () {
    expect(parseCsvLine('T1,A,1-2-3,"[1.0,2.0]",C'),
        ['T1', 'A', '1-2-3', '[1.0,2.0]', 'C']);
    expect(parseCsvLine('a,"b ""q""",c'), ['a', 'b "q"', 'c']);
  });
}
