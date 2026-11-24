import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pattern_sensor_collector/data_management_screen.dart';
import 'package:pattern_sensor_collector/drive_upload_service.dart';
import 'package:pattern_sensor_collector/export_workflow.dart';
import 'package:pattern_sensor_collector/google_auth_service.dart';
import 'package:pattern_sensor_collector/model.dart';
import 'package:pattern_sensor_collector/storage.dart';
import 'package:pattern_sensor_collector/upload_queue_store.dart';

class _SignedInAuth implements DriveAuthProvider {
  @override
  String? get accountRef => 'research-account';

  @override
  Future<String> driveAccessToken({required bool interactive}) async =>
      'test-token';
}

TrialRecord _trial(String id, String participantId) {
  final sensors = <SensorSample>[];
  for (var i = 0; i <= 500; i++) {
    final time = 100.0 + i * 0.01;
    sensors.add(SensorSample(time, 1, 2, 9.8, 'ACCEL'));
    sensors.add(SensorSample(time + 0.005, 0.1, 0.2, 0.3, 'GYRO'));
  }
  return TrialRecord(
    id: id,
    sessionId: 'S1',
    index: 1,
    participantId: participantId,
    deviceId: 'phone1',
    hand: 'right',
    posture: 'seated',
    holdingHand: 'left',
    target: const [1, 2, 5, 8],
    visits: const [
      NodeVisit(1, 100.6, 'touch_detected', false),
      NodeVisit(2, 100.7, 'touch_detected', true),
      NodeVisit(5, 100.8, 'touch_detected', true),
      NodeVisit(8, 100.9, 'touch_detected', true),
    ],
    touches: const [
      TouchSample(100.6, 0.25, 0.25, 'DOWN'),
      TouchSample(101.1, 0.5, 0.75, 'UP'),
    ],
    sensors: sensors,
    start: 100.6,
    end: 101.1,
    clockErrorMs: 1,
    platform: 'test',
    model: 'test',
    osVersion: 'test',
    captureMode: TrialRecord.fixedWindow5Mode,
    buttonT0Monotonic: 100,
    captureStartMonotonic: 100.0,
    captureEndMonotonic: 105.0,
    actualTouchDown: 100.6,
    actualTouchUp: 101.1,
    windowComplete: true,
    buttonDispatchDelayMs: 5,
  );
}

String _zipText(List<int> bytes, String name) {
  final entry = ZipDecoder()
      .decodeBytes(bytes)
      .files
      .firstWhere((item) => item.name == name);
  return utf8.decode(entry.content as List<int>);
}

void main() {
  test('Drive selection separates two participants with one pattern', () async {
    final root = await Directory.systemTemp.createTemp('cross_participant_');
    addTearDown(() => root.delete(recursive: true));
    final storage = SessionStorage(root);
    await storage.saveTrial(_trial('T101', 'P1'));
    await storage.saveTrial(_trial('T202', 'P2'));

    final sent = <(Map<String, dynamic>, List<int>)>[];
    Map<String, dynamic>? pendingMetadata;
    var folderLookups = 0;
    final client = MockClient((request) async {
      if (request.method == 'GET' && request.url.path == '/drive/v3/files') {
        folderLookups++;
        return http.Response(
          jsonEncode({
            'files': [
              {
                'id': 'pattern-folder',
                'name': '1-2-5-8',
                'mimeType': 'application/vnd.google-apps.folder',
                'parents': [teamFolderId],
              },
            ],
          }),
          200,
        );
      }
      if (request.method == 'POST' &&
          request.url.path == '/upload/drive/v3/files') {
        pendingMetadata =
            Map<String, dynamic>.from(jsonDecode(request.body) as Map);
        return http.Response('', 200, headers: {
          'location':
              'https://www.googleapis.com/upload/drive/v3/files?upload_id=test',
        });
      }
      if (request.method == 'PUT' &&
          request.url.path == '/upload/drive/v3/files') {
        final metadata = pendingMetadata;
        expect(metadata, isNotNull);
        sent.add((metadata!, request.bodyBytes));
        return http.Response(
          jsonEncode({
            'id': 'uploaded-${sent.length}',
            'name': metadata['name'],
            'parents': metadata['parents'],
          }),
          200,
        );
      }
      fail('Unexpected Drive request: ${request.method} ${request.url}');
    });
    addTearDown(client.close);
    final queue = UploadQueueStore(root);
    final workflow = ExportWorkflow(
      storage,
      queue,
      _SignedInAuth(),
      DriveUploadService(client),
    );

    final batches = planDriveUploadBatches(await storage.loadSummaries());
    expect(batches, hasLength(2));
    for (final batch in batches) {
      final job = await workflow.prepare(
        batch.map((summary) => summary.id).toSet(),
        diagnostics: false,
      );
      await workflow.upload(job);
    }
    expect(sent, hasLength(2));
    expect(folderLookups, 2);
    final jobs = await queue.load();
    expect(jobs, hasLength(2));
    expect(jobs.every((job) => job.state == 'uploaded'), isTrue);
    expect(jobs.every((job) => job.uploadParentId == 'pattern-folder'), isTrue);
    expect(jobs.map((job) => job.filename).toSet(), hasLength(2));

    final participants = <String>{};
    for (final (metadata, bytes) in sent) {
      expect(metadata['parents'], ['pattern-folder']);
      final trialRows = const LineSplitter()
          .convert(_zipText(bytes, 'trials.csv'))
          .where((line) => line.isNotEmpty)
          .toList();
      expect(trialRows, hasLength(2));
      final fields =
          trialRows.singleWhere((line) => line != trialHeader).split(',');
      final participant = fields[1];
      participants.add(participant);
      expect(participant, anyOf('P1', 'P2'));
      expect(metadata['name'], startsWith('${participant}_'));
      expect(metadata['name'], contains('_1-2-5-8_'));
      final sensorRows = const LineSplitter()
          .convert(_zipText(bytes, 'sensor_events.csv'))
          .where((line) => line.isNotEmpty)
          .skip(1);
      expect(
          sensorRows.every((line) => line.startsWith('${fields[0]},')), isTrue);
    }
    expect(participants, {'P1', 'P2'});
  });
}
