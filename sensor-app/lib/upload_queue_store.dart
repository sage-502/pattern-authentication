import 'dart:convert';
import 'dart:io';

const teamFolderId = '1TL4q-bXzogl5LEL2uS0qj055K0nxnNAI';

class ExportJob {
  final String exportId, filename, localZipPath, folderId, state, createdAtUtc;
  final List<String> trialIds;
  final String? accountRef,
      driveFileId,
      webViewLink,
      lastErrorCode,
      uploadedAtUtc,
      resumableSessionUri,
      patternKey,
      destinationFolderId;
  final bool usePatternFolder;
  final int attemptCount;
  const ExportJob({
    required this.exportId,
    required this.filename,
    required this.localZipPath,
    required this.state,
    required this.createdAtUtc,
    required this.trialIds,
    this.folderId = teamFolderId,
    this.accountRef,
    this.driveFileId,
    this.webViewLink,
    this.lastErrorCode,
    this.uploadedAtUtc,
    this.resumableSessionUri,
    this.patternKey,
    this.destinationFolderId,
    this.usePatternFolder = false,
    this.attemptCount = 0,
  });

  // Old queue snapshots have no usePatternFolder flag and keep their original
  // team-root destination on retry. New jobs pin the resolved child folder.
  String get uploadParentId =>
      usePatternFolder ? destinationFolderId ?? '' : folderId;

  ExportJob change({
    String? state,
    String? accountRef,
    String? driveFileId,
    String? webViewLink,
    String? lastErrorCode,
    String? uploadedAtUtc,
    String? resumableSessionUri,
    String? destinationFolderId,
    bool clearSession = false,
    int? attemptCount,
  }) =>
      ExportJob(
        exportId: exportId,
        filename: filename,
        localZipPath: localZipPath,
        folderId: folderId,
        state: state ?? this.state,
        createdAtUtc: createdAtUtc,
        trialIds: trialIds,
        accountRef: accountRef ?? this.accountRef,
        driveFileId: driveFileId ?? this.driveFileId,
        webViewLink: webViewLink ?? this.webViewLink,
        lastErrorCode: lastErrorCode,
        uploadedAtUtc: uploadedAtUtc ?? this.uploadedAtUtc,
        resumableSessionUri: clearSession
            ? null
            : resumableSessionUri ?? this.resumableSessionUri,
        patternKey: patternKey,
        destinationFolderId: destinationFolderId ?? this.destinationFolderId,
        usePatternFolder: usePatternFolder,
        attemptCount: attemptCount ?? this.attemptCount,
      );

  Map<String, Object?> toJson() => {
        'export_id': exportId,
        'filename': filename,
        'local_zip_path': localZipPath,
        'folder_id': folderId,
        'state': state,
        'created_at_utc': createdAtUtc,
        'trial_ids': trialIds,
        'account_ref': accountRef,
        'drive_file_id': driveFileId,
        'web_view_link': webViewLink,
        'last_error_code': lastErrorCode,
        'uploaded_at_utc': uploadedAtUtc,
        'resumable_session_uri': resumableSessionUri,
        'pattern_key': patternKey,
        'destination_folder_id': destinationFolderId,
        'use_pattern_folder': usePatternFolder,
        'attempt_count': attemptCount,
      };
  factory ExportJob.fromJson(Map<String, dynamic> j) => ExportJob(
        exportId: j['export_id'] as String,
        filename: j['filename'] as String,
        localZipPath: j['local_zip_path'] as String,
        state: j['state'] as String,
        createdAtUtc: j['created_at_utc'] as String,
        trialIds: (j['trial_ids'] as List).cast<String>(),
        folderId: j['folder_id'] as String? ?? teamFolderId,
        accountRef: j['account_ref'] as String?,
        driveFileId: j['drive_file_id'] as String?,
        webViewLink: j['web_view_link'] as String?,
        lastErrorCode: j['last_error_code'] as String?,
        uploadedAtUtc: j['uploaded_at_utc'] as String?,
        resumableSessionUri: j['resumable_session_uri'] as String?,
        patternKey: j['pattern_key'] as String?,
        destinationFolderId: j['destination_folder_id'] as String?,
        usePatternFolder: j['use_pattern_folder'] as bool? ?? false,
        attemptCount: (j['attempt_count'] as num?)?.toInt() ?? 0,
      );
}

/// Each flushed state is a new file. An interrupted update leaves the previous
/// snapshot intact, which is important when a remote response is uncertain.
class UploadQueueStore {
  final Directory root;
  UploadQueueStore(this.root);
  Directory get jobs => Directory('${root.path}/upload_jobs');

  Future<List<ExportJob>> load() async {
    if (!await jobs.exists()) return [];
    final result = <ExportJob>[];
    await for (final entry in jobs.list()) {
      if (entry is! Directory) continue;
      final id = entry.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(id)) continue;
      final snapshots = await entry
          .list()
          .where((e) => e is File && e.path.endsWith('.json'))
          .cast<File>()
          .toList();
      if (snapshots.isEmpty) continue;
      snapshots.sort((a, b) => a.path.compareTo(b.path));
      result.add(
        ExportJob.fromJson(
          Map<String, dynamic>.from(
            jsonDecode(await snapshots.last.readAsString()),
          ),
        ),
      );
    }
    return result;
  }

  Future<ExportJob?> get(String id) async {
    for (final job in await load()) {
      if (job.exportId == id) return job;
    }
    return null;
  }

  Future<void> put(ExportJob job) async {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(job.exportId) ||
        job.folderId != teamFolderId ||
        (job.usePatternFolder &&
            job.patternKey != null &&
            !RegExp(r'^[1-9](?:-[1-9]){2,8}$').hasMatch(job.patternKey!)) ||
        (job.destinationFolderId != null &&
            !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(job.destinationFolderId!)) ||
        File(job.localZipPath).uri.pathSegments.last != job.filename) {
      throw StateError('Invalid upload job');
    }
    final dir = Directory('${jobs.path}/${job.exportId}');
    await dir.create(recursive: true);
    final existing = await dir.list().where((e) => e is File).toList();
    final sequence = existing.length.toString().padLeft(8, '0');
    final finalFile = File('${dir.path}/$sequence.json');
    if (await finalFile.exists()) throw StateError('Upload state collision');
    final temp = File('${finalFile.path}.tmp');
    await temp.writeAsString(jsonEncode(job.toJson()), flush: true);
    await temp.rename(finalFile.path);
  }
}
