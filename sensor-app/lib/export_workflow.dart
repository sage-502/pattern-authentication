import 'dart:io';

import 'package:http/http.dart' as http;

import 'drive_upload_service.dart';
import 'google_auth_service.dart';
import 'storage.dart';
import 'upload_queue_store.dart';

/// Local export and network upload are separate. A retry reuses the same ZIP.
class ExportWorkflow {
  final SessionStorage storage;
  final UploadQueueStore queue;
  final DriveAuthProvider auth;
  final DriveUploadService drive;
  final http.Client? _ownedClient;
  bool _busy = false;

  ExportWorkflow(this.storage, this.queue, this.auth, this.drive)
      : _ownedClient = null;
  ExportWorkflow._owned(
    this.storage,
    this.queue,
    this.auth,
    this.drive,
    this._ownedClient,
  );
  factory ExportWorkflow.production(SessionStorage storage) {
    final client = http.Client();
    return ExportWorkflow._owned(
      storage,
      UploadQueueStore(storage.root),
      GoogleAuthService.instance,
      DriveUploadService(client),
      client,
    );
  }
  void dispose() => _ownedClient?.close();

  Future<ExportJob> prepare(
    Set<String> ids, {
    required bool diagnostics,
    bool legacy = false,
    bool splitByPattern = false,
    int excludedFailed = 0,
    int excludedReview = 0,
    bool Function()? cancelled,
  }) async {
    final artifact = await storage.createExportSelected(
      ids,
      diagnostics: diagnostics,
      legacy: legacy,
      splitByPattern: splitByPattern,
      excludedFailed: excludedFailed,
      excludedReview: excludedReview,
      cancelled: cancelled,
    );
    final filename = artifact.zip.uri.pathSegments.last;
    final patternKey = artifact.targetPatterns.length == 1
        ? artifact.targetPatterns.single
        : null;
    final job = ExportJob(
      exportId: artifact.exportId,
      filename: filename,
      localZipPath: artifact.zip.path,
      state: 'local_ready',
      createdAtUtc: DateTime.now().toUtc().toIso8601String(),
      trialIds: ids.toList()..sort(),
      patternKey: patternKey,
      usePatternFolder: true,
    );
    await queue.put(job);
    return job;
  }

  Future<ExportJob> upload(ExportJob job) async {
    if (_busy) throw StateError('이미 업로드 중입니다.');
    _busy = true;
    try {
      var current = await queue.get(job.exportId) ?? job;
      if (current.state == 'uploaded' && current.driveFileId != null) {
        return current;
      }
      if (!await File(current.localZipPath).exists()) {
        throw StateError('로컬 ZIP이 없습니다. 원본 기록은 유지됩니다.');
      }
      if (current.usePatternFolder) {
        final summaries = {
          for (final summary in await storage.loadSummaries())
            summary.id: summary,
        };
        final chosen = current.trialIds.map((id) => summaries[id]).toList();
        if (chosen.isEmpty || chosen.any((summary) => summary == null)) {
          throw StateError('업로드 ZIP의 원본 기록을 확인할 수 없습니다.');
        }
        final participants =
            chosen.map((summary) => summary!.participantId).toSet();
        final patterns =
            chosen.map((summary) => summary!.targetPattern).toSet();
        if (participants.length != 1 ||
            patterns.length != 1 ||
            patterns.single != current.patternKey) {
          throw StateError('Drive 업로드는 참가자와 목표 패턴별로 나눈 ZIP만 허용합니다.');
        }
      }
      final ref = auth.accountRef;
      if (ref == null) {
        current = current.change(state: 'waiting_for_auth');
        await queue.put(current);
        throw StateError('Google 계정을 연결해 주세요. ZIP은 기기에 보관했습니다.');
      }
      if (current.accountRef != null && current.accountRef != ref) {
        throw StateError('이 ZIP은 다른 Google 계정의 대기 작업입니다. 원래 계정으로 연결해 주세요.');
      }
      current = current.change(accountRef: ref);
      await queue.put(current);
      final accessToken = await auth.driveAccessToken(interactive: true);
      if (current.usePatternFolder) {
        final pattern = current.patternKey;
        if (pattern == null) {
          throw StateError('Drive 업로드는 목표 패턴별 ZIP으로 나눠야 합니다.');
        }
        final folderId = await drive.ensurePatternFolder(
          accessToken,
          pattern,
          knownFolderId: current.destinationFolderId,
        );
        if (current.destinationFolderId != folderId) {
          current = current.change(destinationFolderId: folderId);
          await queue.put(current);
        }
      }
      if (current.state == 'unknown_remote_state' ||
          current.state == 'uploading') {
        DriveFileResult? found;
        if (current.resumableSessionUri != null) {
          try {
            found = await drive.resume(
              accessToken,
              current,
              Uri.parse(current.resumableSessionUri!),
            );
          } on DriveUploadException catch (e) {
            if (e.code != 'FOLDER_NOT_FOUND') rethrow;
          }
        }
        found ??= await drive.findUploaded(
          accessToken,
          current.exportId,
          current.uploadParentId,
        );
        if (found != null &&
            found.name == current.filename &&
            found.parents.contains(current.uploadParentId)) {
          current = current.change(
            state: 'uploaded',
            driveFileId: found.id,
            webViewLink: found.webViewLink,
            clearSession: true,
            uploadedAtUtc: DateTime.now().toUtc().toIso8601String(),
          );
          await queue.put(current);
          return current;
        }
        current = current.change(
          state: 'unknown_remote_state',
          lastErrorCode: 'REMOTE_STATUS_UNCONFIRMED',
        );
        await queue.put(current);
        throw StateError('이전 업로드 결과를 확인할 수 없어 중복 전송을 막았습니다. 팀 폴더를 확인하세요.');
      }
      current = current.change(
        state: 'uploading',
        attemptCount: current.attemptCount + 1,
      );
      await queue.put(current);
      final result = await drive.upload(
        accessToken,
        current,
        onSession: (session) async {
          current = current.change(resumableSessionUri: session.toString());
          await queue.put(current);
        },
      );
      current = current.change(
        state: 'uploaded',
        driveFileId: result.id,
        webViewLink: result.webViewLink,
        clearSession: true,
        uploadedAtUtc: DateTime.now().toUtc().toIso8601String(),
      );
      await queue.put(current);
      return current;
    } on DriveUploadException catch (e) {
      final current = await queue.get(job.exportId);
      if (current != null) {
        await queue.put(
          current.change(
            state: e.remoteMayExist || current.state == 'unknown_remote_state'
                ? 'unknown_remote_state'
                : e.code.startsWith('FOLDER_')
                    ? 'failed_permission'
                    : 'failed_retryable',
            lastErrorCode: e.code,
          ),
        );
      }
      rethrow;
    } catch (_) {
      final current = await queue.get(job.exportId);
      if (current != null && current.state == 'uploading') {
        await queue.put(
          current.change(
            state: current.resumableSessionUri == null
                ? 'failed_retryable'
                : 'unknown_remote_state',
            lastErrorCode: 'UPLOAD_INTERRUPTED',
          ),
        );
      }
      rethrow;
    } finally {
      _busy = false;
    }
  }
}
