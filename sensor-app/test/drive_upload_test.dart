import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pattern_sensor_collector/data_management.dart';
import 'package:pattern_sensor_collector/drive_upload_service.dart';
import 'package:pattern_sensor_collector/export_workflow.dart';
import 'package:pattern_sensor_collector/google_auth_service.dart';
import 'package:pattern_sensor_collector/storage.dart';
import 'package:pattern_sensor_collector/upload_queue_store.dart';

class _FakeAuth implements DriveAuthProvider {
  @override
  String? accountRef;
  _FakeAuth(this.accountRef);
  @override
  Future<String> driveAccessToken({required bool interactive}) async =>
      'test-token';
}

class _SummaryStorage extends SessionStorage {
  final List<TrialSummary> summaries;
  _SummaryStorage(super.root, this.summaries);

  @override
  Future<List<TrialSummary>> loadSummaries() async => summaries;
}

void main() {
  test('mixed participant ZIP cannot reach Drive upload', () async {
    final root = await Directory.systemTemp.createTemp('mixed_upload_test_');
    addTearDown(() => root.delete(recursive: true));
    final zip = File('${root.path}/mixed.zip');
    await zip.writeAsBytes([1, 2, 3]);
    final storage = _SummaryStorage(root, [
      TrialSummary.legacyUnknown('T1', target: '1-2-5-8', participantId: 'P1'),
      TrialSummary.legacyUnknown('T2', target: '1-2-5-8', participantId: 'P2'),
    ]);
    final job = ExportJob(
      exportId: 'a' * 32,
      filename: 'mixed.zip',
      localZipPath: zip.path,
      state: 'local_ready',
      createdAtUtc: DateTime.utc(2026, 11, 5).toIso8601String(),
      trialIds: ['T1', 'T2'],
      patternKey: '1-2-5-8',
      usePatternFolder: true,
    );
    final client = MockClient((_) async => fail('Network must not be called'));
    final workflow = ExportWorkflow(storage, UploadQueueStore(root),
        _FakeAuth('account'), DriveUploadService(client));
    await expectLater(workflow.upload(job), throwsA(isA<StateError>()));
    expect(await zip.readAsBytes(), [1, 2, 3]);
    client.close();
  });

  test('existing direct child pattern folder is reused', () async {
    var creates = 0;
    final client = MockClient((request) async {
      if (request.method == 'GET') {
        expect(request.url.queryParameters['q'],
            contains("'$teamFolderId' in parents"));
        return http.Response(
            jsonEncode({
              'files': [
                {
                  'id': 'child-existing',
                  'name': '1-2-5-8',
                  'mimeType': 'application/vnd.google-apps.folder',
                  'parents': [teamFolderId]
                }
              ]
            }),
            200);
      }
      creates++;
      return http.Response('{}', 500);
    });
    final id = await DriveUploadService(client)
        .ensurePatternFolder('test-token', '1-2-5-8');
    expect(id, 'child-existing');
    expect(creates, 0);
    client.close();
  });

  test('missing pattern folder is created beneath fixed team root', () async {
    var creates = 0;
    final client = MockClient((request) async {
      if (request.method == 'GET') return http.Response('{"files":[]}', 200);
      creates++;
      final metadata = jsonDecode(request.body) as Map<String, dynamic>;
      expect(metadata['name'], '1-4-7-8');
      expect(metadata['mimeType'], 'application/vnd.google-apps.folder');
      expect(metadata['parents'], [teamFolderId]);
      return http.Response(
          jsonEncode({
            'id': 'child-created',
            'name': '1-4-7-8',
            'mimeType': 'application/vnd.google-apps.folder',
            'parents': [teamFolderId]
          }),
          201);
    });
    final id = await DriveUploadService(client)
        .ensurePatternFolder('test-token', '1-4-7-8');
    expect(id, 'child-created');
    expect(creates, 1);
    client.close();
  });

  test('duplicate pattern folders stop upload instead of choosing one',
      () async {
    final client = MockClient((_) async => http.Response(
        jsonEncode({
          'files': [
            {
              'id': 'child-a',
              'name': '1-2-5-8',
              'mimeType': 'application/vnd.google-apps.folder',
              'parents': [teamFolderId]
            },
            {
              'id': 'child-b',
              'name': '1-2-5-8',
              'mimeType': 'application/vnd.google-apps.folder',
              'parents': [teamFolderId]
            }
          ]
        }),
        200));
    await expectLater(
      DriveUploadService(client).ensurePatternFolder('test-token', '1-2-5-8'),
      throwsA(isA<DriveUploadException>()
          .having((e) => e.code, 'code', 'PATTERN_FOLDER_AMBIGUOUS')),
    );
    client.close();
  });

  test('pattern folder permission failure has a distinct error', () async {
    final client = MockClient((_) async => http.Response('{}', 403));
    await expectLater(
      DriveUploadService(client).ensurePatternFolder('test-token', '1-2-5-8'),
      throwsA(isA<DriveUploadException>()
          .having((e) => e.code, 'code', 'PATTERN_FOLDER_LOOKUP_DENIED')),
    );
    client.close();
  });

  test('a failed second search page never creates a folder', () async {
    var creates = 0;
    final client = MockClient((request) async {
      if (request.method == 'POST') {
        creates++;
        return http.Response('{}', 201);
      }
      expect(request.url.queryParameters['q'],
          contains("'$teamFolderId' in parents"));
      if (request.url.queryParameters['pageToken'] == null) {
        return http.Response('{"files":[],"nextPageToken":"next"}', 200);
      }
      return http.Response('{"error":{"code":503}}', 503);
    });
    await expectLater(
      DriveUploadService(client).ensurePatternFolder('token', '1-2-5-8'),
      throwsA(isA<DriveUploadException>()
          .having((e) => e.code, 'code', 'RETRYABLE_NETWORK')),
    );
    expect(creates, 0);
    client.close();
  });

  test('incomplete or malformed search is not treated as an empty folder',
      () async {
    for (final (body, code) in [
      (
        '{"files":[],"incompleteSearch":true}',
        'PATTERN_FOLDER_SEARCH_INCOMPLETE'
      ),
      ('{"nextPageToken":null}', 'PATTERN_FOLDER_SEARCH_INVALID'),
      ('not json', 'PATTERN_FOLDER_SEARCH_INVALID'),
    ]) {
      var creates = 0;
      final client = MockClient((request) async {
        if (request.method == 'POST') creates++;
        return http.Response(body, 200);
      });
      await expectLater(
        DriveUploadService(client).ensurePatternFolder('token', '1-2-5-8'),
        throwsA(
            isA<DriveUploadException>().having((e) => e.code, 'code', code)),
      );
      expect(creates, 0);
      client.close();
    }
  });

  test('different account tokens reuse the same visible team pattern folder',
      () async {
    final requestedTokens = <String>[];
    var creates = 0;
    final client = MockClient((request) async {
      requestedTokens.add(request.headers['authorization'] ?? '');
      expect(request.url.queryParameters['q'],
          contains("'$teamFolderId' in parents"));
      if (request.method == 'POST') creates++;
      return http.Response(
          jsonEncode({
            'files': [
              {
                'id': 'shared-pattern-id',
                'name': '1-2-5-8',
                'mimeType': 'application/vnd.google-apps.folder',
                'parents': [teamFolderId]
              }
            ]
          }),
          200);
    });
    final service = DriveUploadService(client);
    expect(await service.ensurePatternFolder('account-a', '1-2-5-8'),
        'shared-pattern-id');
    expect(await service.ensurePatternFolder('account-b', '1-2-5-8'),
        'shared-pattern-id');
    expect(requestedTokens, ['Bearer account-a', 'Bearer account-b']);
    expect(creates, 0);
    client.close();
  });

  test('new ZIP uploads into resolved pattern folder', () async {
    final root = await Directory.systemTemp.createTemp('pattern_upload_test_');
    addTearDown(() => root.delete(recursive: true));
    final zip = File('${root.path}/short.zip')..writeAsBytesSync([1, 2, 3]);
    final job = ExportJob(
      exportId: '1' * 32,
      filename: 'short.zip',
      localZipPath: zip.path,
      state: 'local_ready',
      createdAtUtc: DateTime.utc(2026, 11, 5).toIso8601String(),
      trialIds: ['T1'],
      patternKey: '1-2-5-8',
      usePatternFolder: true,
      destinationFolderId: 'child-folder',
    );
    final client = MockClient((request) async {
      if (request.method == 'POST') {
        expect((jsonDecode(request.body) as Map)['parents'], ['child-folder']);
        return http.Response('', 200, headers: {
          'location':
              'https://www.googleapis.com/upload/drive/v3/files?upload_id=child'
        });
      }
      return http.Response(
          jsonEncode({
            'id': 'uploaded-child',
            'name': 'short.zip',
            'parents': ['child-folder']
          }),
          200);
    });
    final result = await DriveUploadService(client)
        .upload('test-token', job, onSession: (_) async {});
    expect(result.id, 'uploaded-child');
    client.close();
  });

  test('two account tokens route their ZIPs to one existing pattern folder',
      () async {
    final root = await Directory.systemTemp.createTemp('two_account_upload_');
    addTearDown(() => root.delete(recursive: true));
    final uploads = <String>[];
    final client = MockClient((request) async {
      final token = request.headers['authorization'] ?? '';
      if (request.method == 'GET') {
        expect(request.url.queryParameters['q'],
            contains("'$teamFolderId' in parents"));
        return http.Response(
            jsonEncode({
              'files': [
                {
                  'id': 'shared-pattern-id',
                  'name': '1-2-5-8',
                  'mimeType': 'application/vnd.google-apps.folder',
                  'parents': [teamFolderId]
                }
              ]
            }),
            200);
      }
      if (request.method == 'POST') {
        expect((jsonDecode(request.body) as Map)['parents'],
            ['shared-pattern-id']);
        uploads.add(token);
        return http.Response('', 200, headers: {
          'location':
              'https://www.googleapis.com/upload/drive/v3/files?upload_id=mock'
        });
      }
      final name = token == 'Bearer account-a' ? 'a.zip' : 'b.zip';
      return http.Response(
          jsonEncode({
            'id': 'file-$name',
            'name': name,
            'parents': ['shared-pattern-id']
          }),
          200);
    });
    final service = DriveUploadService(client);
    for (final (token, name, id) in [
      ('account-a', 'a.zip', 'a' * 32),
      ('account-b', 'b.zip', 'b' * 32),
    ]) {
      final folderId = await service.ensurePatternFolder(token, '1-2-5-8');
      expect(folderId, 'shared-pattern-id');
      final zip = File('${root.path}/$name')..writeAsBytesSync([1, 2, 3]);
      final job = ExportJob(
        exportId: id,
        filename: name,
        localZipPath: zip.path,
        state: 'local_ready',
        createdAtUtc: DateTime.utc(2026, 11, 5).toIso8601String(),
        trialIds: ['T$id'],
        patternKey: '1-2-5-8',
        usePatternFolder: true,
        destinationFolderId: folderId,
      );
      final uploaded =
          await service.upload(token, job, onSession: (_) async {});
      expect(uploaded.parents, ['shared-pattern-id']);
    }
    expect(uploads, ['Bearer account-a', 'Bearer account-b']);
    client.close();
  });

  test('workflow pins child folder and does not upload again after success',
      () async {
    final root = await Directory.systemTemp.createTemp('folder_workflow_test_');
    addTearDown(() => root.delete(recursive: true));
    final zip = File('${root.path}/short.zip')..writeAsBytesSync([4, 5, 6]);
    final job = ExportJob(
      exportId: '2' * 32,
      filename: 'short.zip',
      localZipPath: zip.path,
      state: 'local_ready',
      createdAtUtc: DateTime.utc(2026, 11, 5).toIso8601String(),
      trialIds: ['T2'],
      patternKey: '1-2-5-8',
      usePatternFolder: true,
    );
    final queue = UploadQueueStore(root);
    await queue.put(job);
    var folderCreates = 0, zipCreates = 0;
    final client = MockClient((request) async {
      if (request.method == 'GET') {
        return http.Response('{"files":[]}', 200);
      }
      if (request.url.path == '/drive/v3/files') {
        folderCreates++;
        return http.Response(
            jsonEncode({
              'id': 'child-workflow',
              'name': '1-2-5-8',
              'mimeType': 'application/vnd.google-apps.folder',
              'parents': [teamFolderId]
            }),
            201);
      }
      if (request.method == 'POST') {
        zipCreates++;
        expect(
            (jsonDecode(request.body) as Map)['parents'], ['child-workflow']);
        return http.Response('', 200, headers: {
          'location':
              'https://www.googleapis.com/upload/drive/v3/files?upload_id=workflow'
        });
      }
      return http.Response(
          jsonEncode({
            'id': 'remote-workflow',
            'name': 'short.zip',
            'parents': ['child-workflow']
          }),
          200);
    });
    final storage = _SummaryStorage(root, [
      TrialSummary.legacyUnknown('T2', target: '1-2-5-8', participantId: 'P1'),
    ]);
    final workflow = ExportWorkflow(storage, queue, _FakeAuth('opaque-account'),
        DriveUploadService(client));
    final first = await workflow.upload(job);
    expect(first.driveFileId, 'remote-workflow');
    expect(first.destinationFolderId, 'child-workflow');
    final restored = await queue.get(job.exportId);
    expect(restored?.uploadParentId, 'child-workflow');
    final again = await workflow.upload(job);
    expect(again.driveFileId, 'remote-workflow');
    expect(folderCreates, 1);
    expect(zipCreates, 1);
    client.close();
  });

  test('old queue JSON without folder fields keeps team-root retry target',
      () async {
    final root = await Directory.systemTemp.createTemp('old_queue_test_');
    addTearDown(() => root.delete(recursive: true));
    final id = '3' * 32;
    final dir = Directory('${root.path}/upload_jobs/$id');
    await dir.create(recursive: true);
    await File('${dir.path}/00000000.json').writeAsString(jsonEncode({
      'export_id': id,
      'filename': 'old.zip',
      'local_zip_path': '${root.path}/old.zip',
      'folder_id': teamFolderId,
      'state': 'failed_retryable',
      'created_at_utc': DateTime.utc(2026, 11, 4).toIso8601String(),
      'trial_ids': ['T3']
    }));
    final old = await UploadQueueStore(root).get(id);
    expect(old?.usePatternFolder, false);
    expect(old?.uploadParentId, teamFolderId);
    expect(old?.patternKey, null);
  });

  test('missing sign-in leaves ZIP ready and creates no upload attempt',
      () async {
    final root = await Directory.systemTemp.createTemp('auth_test_');
    addTearDown(() => root.delete(recursive: true));
    final zip = File('${root.path}/file.zip');
    await zip.writeAsBytes([1, 2, 3]);
    final job = ExportJob(
      exportId: 'e' * 32,
      filename: 'file.zip',
      localZipPath: zip.path,
      state: 'local_ready',
      createdAtUtc: DateTime.utc(2026, 11, 5).toIso8601String(),
      trialIds: ['T5'],
    );
    final queue = UploadQueueStore(root);
    await queue.put(job);
    final client = MockClient((_) async => fail('Network must not be called'));
    final workflow = ExportWorkflow(SessionStorage(root), queue,
        _FakeAuth(null), DriveUploadService(client));
    await expectLater(workflow.upload(job), throwsA(isA<StateError>()));
    final saved = await queue.get(job.exportId);
    expect(saved?.state, 'waiting_for_auth');
    expect(saved?.attemptCount, 0);
    expect(await zip.readAsBytes(), [1, 2, 3]);
    client.close();
  });

  test('server failure retries the same ZIP and confirms one Drive file',
      () async {
    final root = await Directory.systemTemp.createTemp('retry_test_');
    addTearDown(() => root.delete(recursive: true));
    final zip = File('${root.path}/file.zip');
    await zip.writeAsBytes([1, 2, 3]);
    final job = ExportJob(
      exportId: 'f' * 32,
      filename: 'file.zip',
      localZipPath: zip.path,
      state: 'local_ready',
      createdAtUtc: DateTime.utc(2026, 11, 5).toIso8601String(),
      trialIds: ['T6'],
    );
    final queue = UploadQueueStore(root);
    await queue.put(job);
    var initiations = 0;
    var transfers = 0;
    final client = MockClient((request) async {
      if (request.method == 'POST') {
        initiations++;
        expect((jsonDecode(request.body) as Map)['parents'], [teamFolderId]);
        if (initiations == 1) return http.Response('{}', 503);
        return http.Response('', 200, headers: {
          'location':
              'https://www.googleapis.com/upload/drive/v3/files?upload_id=retry',
        });
      }
      transfers++;
      expect(request.bodyBytes, [1, 2, 3]);
      return http.Response(
        jsonEncode({
          'id': 'remote-retry',
          'name': 'file.zip',
          'parents': [teamFolderId],
        }),
        200,
      );
    });
    final workflow = ExportWorkflow(SessionStorage(root), queue,
        _FakeAuth('opaque-account'), DriveUploadService(client));
    await expectLater(
        workflow.upload(job), throwsA(isA<DriveUploadException>()));
    expect((await queue.get(job.exportId))?.state, 'failed_retryable');
    expect(await zip.readAsBytes(), [1, 2, 3]);
    final confirmed = await workflow.upload(job);
    expect(confirmed.state, 'uploaded');
    expect(confirmed.driveFileId, 'remote-retry');
    expect(confirmed.attemptCount, 2);
    expect(initiations, 2);
    expect(transfers, 1);
    expect(await zip.readAsBytes(), [1, 2, 3]);
    client.close();
  });

  test('folder app approval failure preserves local ZIP and narrow scope',
      () async {
    final root = await Directory.systemTemp.createTemp('approval_test_');
    addTearDown(() => root.delete(recursive: true));
    final zip = File('${root.path}/file.zip');
    await zip.writeAsBytes([1, 2, 3]);
    final job = ExportJob(
      exportId: 'd' * 32,
      filename: 'file.zip',
      localZipPath: zip.path,
      state: 'local_ready',
      createdAtUtc: DateTime.utc(2026, 11, 5).toIso8601String(),
      trialIds: ['T4'],
    );
    final client = MockClient((request) async {
      expect(request.method, 'POST');
      expect((jsonDecode(request.body) as Map)['parents'], [teamFolderId]);
      return http.Response(
        jsonEncode({
          'error': {
            'errors': [
              {'reason': 'appNotAuthorizedToFile'}
            ]
          }
        }),
        403,
      );
    });
    await expectLater(
      DriveUploadService(client)
          .upload('test-token', job, onSession: (_) async {}),
      throwsA(isA<DriveUploadException>()
          .having((e) => e.code, 'code', 'FOLDER_APP_APPROVAL_REQUIRED')),
    );
    expect(await zip.readAsBytes(), [1, 2, 3]);
    client.close();
  });

  test('authentication and server failures remain distinguishable', () async {
    for (final (status, code) in [
      (401, 'AUTH_EXPIRED'),
      (403, 'FOLDER_WRITE_DENIED'),
      (503, 'RETRYABLE_NETWORK'),
    ]) {
      final client = MockClient((_) async => http.Response('{}', status));
      await expectLater(
        DriveUploadService(client).checkFolder('test-token'),
        throwsA(
            isA<DriveUploadException>().having((e) => e.code, 'code', code)),
      );
      client.close();
    }
  });

  test('Drive mock uses fixed parent and confirms file ID', () async {
    final root = await Directory.systemTemp.createTemp('drive_test_');
    addTearDown(() => root.delete(recursive: true));
    final zip = File('${root.path}/file.zip');
    await zip.writeAsBytes([1, 2, 3]);
    final job = ExportJob(
        exportId: 'a' * 32,
        filename: 'file.zip',
        localZipPath: zip.path,
        state: 'local_ready',
        createdAtUtc: DateTime.utc(2026, 11, 4).toIso8601String(),
        trialIds: ['T1']);
    var initiated = false, uploaded = false;
    final client = MockClient((request) async {
      expect(request.headers['authorization'], 'Bearer test-token');
      if (request.method == 'POST') {
        expect(request.url.queryParameters['supportsAllDrives'], 'true');
        final metadata = jsonDecode(request.body) as Map<String, dynamic>;
        expect(metadata['parents'], [teamFolderId]);
        expect(metadata['appProperties']['export_id'], job.exportId);
        initiated = true;
        return http.Response('', 200, headers: {
          'location':
              'https://www.googleapis.com/upload/drive/v3/files?upload_id=test',
        });
      }
      expect(request.method, 'PUT');
      expect(request.bodyBytes, [1, 2, 3]);
      uploaded = true;
      return http.Response(
          jsonEncode({
            'id': 'remote-123',
            'name': 'file.zip',
            'parents': [teamFolderId],
            'size': '3'
          }),
          200);
    });
    Uri? session;
    final result = await DriveUploadService(client).upload('test-token', job,
        onSession: (uri) async {
      session = uri;
    });
    expect(initiated, true);
    expect(uploaded, true);
    expect(session?.host, 'www.googleapis.com');
    expect(result.id, 'remote-123');
    client.close();
  });

  test('308 resume sends only remaining bytes', () async {
    final root = await Directory.systemTemp.createTemp('resume_test_');
    addTearDown(() => root.delete(recursive: true));
    final zip = File('${root.path}/file.zip');
    await zip.writeAsBytes([1, 2, 3, 4]);
    final job = ExportJob(
        exportId: 'b' * 32,
        filename: 'file.zip',
        localZipPath: zip.path,
        state: 'unknown_remote_state',
        createdAtUtc: DateTime.utc(2026, 11, 4).toIso8601String(),
        trialIds: ['T2']);
    var count = 0;
    final client = MockClient((request) async {
      count++;
      if (count == 1) {
        expect(request.headers['content-range'], 'bytes */4');
        return http.Response('', 308, headers: {'range': 'bytes=0-1'});
      }
      expect(request.headers['content-range'], 'bytes 2-3/4');
      expect(request.bodyBytes, [3, 4]);
      return http.Response(
          jsonEncode({
            'id': 'remote-resumed',
            'name': 'file.zip',
            'parents': [teamFolderId]
          }),
          200);
    });
    final result = await DriveUploadService(client).resume(
        'test-token',
        job,
        Uri.parse(
            'https://www.googleapis.com/upload/drive/v3/files?upload_id=test'));
    expect(count, 2);
    expect(result.id, 'remote-resumed');
    client.close();
  });

  test('upload state survives restart without deleting prior snapshots',
      () async {
    final root = await Directory.systemTemp.createTemp('queue_test_');
    addTearDown(() => root.delete(recursive: true));
    final job = ExportJob(
        exportId: 'c' * 32,
        filename: 'file.zip',
        localZipPath: '${root.path}/file.zip',
        state: 'unknown_remote_state',
        createdAtUtc: DateTime.utc(2026, 11, 4).toIso8601String(),
        trialIds: ['T3'],
        accountRef: 'opaque-account');
    await UploadQueueStore(root).put(job);
    await UploadQueueStore(root)
        .put(job.change(state: 'uploaded', driveFileId: 'confirmed-id'));
    final restored = await UploadQueueStore(root).get(job.exportId);
    expect(restored?.state, 'uploaded');
    expect(restored?.driveFileId, 'confirmed-id');
    expect(restored?.accountRef, 'opaque-account');
    expect(restored?.usePatternFolder, false);
    expect(restored?.uploadParentId, teamFolderId);
    expect(
        await Directory('${root.path}/upload_jobs/${job.exportId}')
            .list()
            .length,
        2);
  });
}
