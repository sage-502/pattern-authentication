import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'upload_queue_store.dart';

class DriveUploadException implements Exception {
  final String code;
  final bool remoteMayExist;
  const DriveUploadException(this.code, {this.remoteMayExist = false});
  @override
  String toString() => code;
}

String driveErrorMessage(Object error) {
  if (error is DriveUploadException) {
    return switch (error.code) {
      'AUTH_EXPIRED' => 'Google 계정을 다시 연결해 주세요.',
      'FOLDER_NOT_FOUND' => '팀 폴더를 찾거나 읽을 수 없습니다. 공유 권한을 확인하세요.',
      'FOLDER_WRITE_DENIED' => '팀 폴더에 파일 추가 권한이 없습니다. 소유자에게 편집 권한을 요청하세요.',
      'FOLDER_APP_APPROVAL_REQUIRED' =>
        '팀 폴더를 앱에 명시적으로 허용해야 합니다. Google Picker 설정이 필요합니다.',
      'PATTERN_FOLDER_LOOKUP_DENIED' =>
        '패턴 폴더를 검색할 권한이 없습니다. 팀 폴더의 앱 접근 승인을 확인하세요.',
      'PATTERN_FOLDER_SEARCH_INCOMPLETE' =>
        '패턴 폴더 검색 결과가 불완전합니다. 새 폴더를 만들지 않았습니다. 다시 시도하세요.',
      'PATTERN_FOLDER_SEARCH_INVALID' =>
        '패턴 폴더 검색 응답을 확인할 수 없습니다. 새 폴더를 만들지 않았습니다.',
      'PATTERN_FOLDER_CREATE_DENIED' =>
        '패턴 폴더 생성이 거부됐습니다. 팀 폴더 편집 권한과 앱 승인을 확인하세요.',
      'PATTERN_FOLDER_AMBIGUOUS' =>
        '같은 이름의 패턴 폴더가 여러 개입니다. 팀 폴더에서 중복 폴더를 확인하세요.',
      'PATTERN_FOLDER_INVALID' ||
      'PATTERN_FOLDER_RESPONSE_MISMATCH' ||
      'PATTERN_FOLDER_UNRESOLVED' => '패턴 폴더를 안전하게 확인하지 못했습니다. ZIP은 기기에 보관됩니다.',
      'LOCAL_ZIP_MISSING' => '로컬 ZIP이 없어 재시도할 수 없습니다.',
      'RETRYABLE_NETWORK' => '네트워크 또는 Drive 서버 오류입니다. 같은 ZIP을 재시도하세요.',
      'REMOTE_STATUS_UNCONFIRMED' ||
      'UPLOAD_RESPONSE_UNKNOWN' => '원격 상태를 확인할 수 없어 자동 재전송을 중단했습니다.',
      _ => 'Drive 요청 실패 (${error.code}). 로컬 ZIP은 유지됩니다.',
    };
  }
  if (error is StateError) return error.message.toString();
  return 'Google 인증 또는 네트워크 오류입니다. OAuth 설정과 연결 상태를 확인하세요.';
}

class DriveFileResult {
  final String id, name;
  final List<String> parents;
  final String? webViewLink;
  final int? size;
  const DriveFileResult(
    this.id,
    this.name,
    this.parents,
    this.webViewLink,
    this.size,
  );
  factory DriveFileResult.fromJson(Map<String, dynamic> j) => DriveFileResult(
    j['id'] as String? ?? '',
    j['name'] as String? ?? '',
    (j['parents'] as List? ?? []).cast<String>(),
    j['webViewLink'] as String?,
    int.tryParse('${j['size'] ?? ''}'),
  );
}

class DriveUploadService {
  final http.Client client;
  DriveUploadService(this.client);
  static const _fields = 'id,name,parents,size,webViewLink';
  static final _patternPath = RegExp(r'^[1-9](?:-[1-9]){2,8}$');
  static final _driveId = RegExp(r'^[A-Za-z0-9_-]+$');

  Future<String> ensurePatternFolder(
    String token,
    String pattern, {
    String? knownFolderId,
  }) async {
    if (!_patternPath.hasMatch(pattern)) {
      throw const DriveUploadException('PATTERN_FOLDER_INVALID');
    }
    if (knownFolderId != null) {
      if (!_driveId.hasMatch(knownFolderId)) {
        throw const DriveUploadException('PATTERN_FOLDER_INVALID');
      }
      final uri = Uri.https(
        'www.googleapis.com',
        '/drive/v3/files/$knownFolderId',
        {'fields': 'id,name,mimeType,parents', 'supportsAllDrives': 'true'},
      );
      final response = await client.get(
        uri,
        headers: {'Authorization': 'Bearer $token'},
      );
      if (response.statusCode != 200) {
        throw _folderError(response.statusCode, response.body, creating: false);
      }
      final folder = jsonDecode(response.body) as Map<String, dynamic>;
      _validatePatternFolder(folder, pattern, knownFolderId);
      return knownFolderId;
    }

    final found = <String>{};
    final seenPageTokens = <String>{};
    String? pageToken;
    do {
      if (pageToken != null && !seenPageTokens.add(pageToken)) {
        throw const DriveUploadException('PATTERN_FOLDER_SEARCH_INCOMPLETE');
      }
      final uri = Uri.https('www.googleapis.com', '/drive/v3/files', {
        'q':
            "name = '$pattern' and '$teamFolderId' in parents and "
            "mimeType = 'application/vnd.google-apps.folder' and trashed = false",
        'fields':
            'nextPageToken,incompleteSearch,files(id,name,mimeType,parents)',
        'pageSize': '1000',
        'spaces': 'drive',
        'supportsAllDrives': 'true',
        'includeItemsFromAllDrives': 'true',
        if (pageToken != null) 'pageToken': pageToken,
      });
      final response = await client.get(
        uri,
        headers: {'Authorization': 'Bearer $token'},
      );
      if (response.statusCode != 200) {
        throw _folderError(response.statusCode, response.body, creating: false);
      }
      Map<String, dynamic> data;
      try {
        data = Map<String, dynamic>.from(jsonDecode(response.body) as Map);
      } catch (_) {
        throw const DriveUploadException('PATTERN_FOLDER_SEARCH_INVALID');
      }
      if (data['incompleteSearch'] != null &&
          data['incompleteSearch'] is! bool) {
        throw const DriveUploadException('PATTERN_FOLDER_SEARCH_INVALID');
      }
      if (data['incompleteSearch'] == true) {
        throw const DriveUploadException('PATTERN_FOLDER_SEARCH_INCOMPLETE');
      }
      final files = data['files'];
      if (files is! List ||
          (data['nextPageToken'] != null && data['nextPageToken'] is! String)) {
        throw const DriveUploadException('PATTERN_FOLDER_SEARCH_INVALID');
      }
      for (final raw in files) {
        if (raw is! Map) {
          throw const DriveUploadException('PATTERN_FOLDER_SEARCH_INVALID');
        }
        final folder = Map<String, dynamic>.from(raw);
        final id = folder['id'] as String? ?? '';
        _validatePatternFolder(folder, pattern, id);
        found.add(id);
      }
      pageToken = data['nextPageToken'] as String?;
      if (found.length > 1) {
        throw const DriveUploadException('PATTERN_FOLDER_AMBIGUOUS');
      }
    } while (pageToken != null && pageToken.isNotEmpty);
    if (found.isNotEmpty) return found.single;

    final uri = Uri.https('www.googleapis.com', '/drive/v3/files', {
      'fields': 'id,name,mimeType,parents',
      'supportsAllDrives': 'true',
    });
    final response = await client.post(
      uri,
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json; charset=UTF-8',
      },
      body: jsonEncode({
        'name': pattern,
        'mimeType': 'application/vnd.google-apps.folder',
        'parents': [teamFolderId],
      }),
    );
    if (response.statusCode != 200 && response.statusCode != 201) {
      throw _folderError(response.statusCode, response.body, creating: true);
    }
    final folder = jsonDecode(response.body) as Map<String, dynamic>;
    final id = folder['id'] as String? ?? '';
    _validatePatternFolder(folder, pattern, id);
    return id;
  }

  void _validatePatternFolder(
    Map<String, dynamic> folder,
    String pattern,
    String id,
  ) {
    if (!_driveId.hasMatch(id) ||
        folder['id'] != id ||
        folder['name'] != pattern ||
        folder['mimeType'] != 'application/vnd.google-apps.folder' ||
        !(folder['parents'] as List? ?? const []).contains(teamFolderId)) {
      throw const DriveUploadException('PATTERN_FOLDER_RESPONSE_MISMATCH');
    }
  }

  DriveUploadException _folderError(
    int status,
    String body, {
    required bool creating,
  }) {
    final error = _error(status, body);
    if (error.code == 'FOLDER_WRITE_DENIED') {
      return DriveUploadException(
        creating
            ? 'PATTERN_FOLDER_CREATE_DENIED'
            : 'PATTERN_FOLDER_LOOKUP_DENIED',
      );
    }
    return error;
  }

  Future<Map<String, dynamic>> checkFolder(String token) async {
    final uri = Uri.https(
      'www.googleapis.com',
      '/drive/v3/files/$teamFolderId',
      {
        'fields': 'id,name,mimeType,capabilities(canAddChildren)',
        'supportsAllDrives': 'true',
      },
    );
    final response = await client.get(
      uri,
      headers: {'Authorization': 'Bearer $token'},
    );
    if (response.statusCode != 200) {
      throw _error(response.statusCode, response.body);
    }
    final folder = jsonDecode(response.body) as Map<String, dynamic>;
    if (folder['id'] != teamFolderId ||
        folder['mimeType'] != 'application/vnd.google-apps.folder') {
      throw const DriveUploadException('FOLDER_MISMATCH');
    }
    return folder;
  }

  Future<DriveFileResult?> findUploaded(
    String token,
    String exportId,
    String parentId,
  ) async {
    if (!RegExp(r'^[0-9a-f]{32}$').hasMatch(exportId)) {
      throw const DriveUploadException('INVALID_EXPORT_ID');
    }
    if (!_driveId.hasMatch(parentId)) {
      throw const DriveUploadException('PATTERN_FOLDER_INVALID');
    }
    final query =
        "appProperties has { key='export_id' and value='$exportId' } and '$parentId' in parents and trashed = false";
    final uri = Uri.https('www.googleapis.com', '/drive/v3/files', {
      'q': query,
      'fields': 'files($_fields),nextPageToken',
      'spaces': 'drive',
      'supportsAllDrives': 'true',
      'includeItemsFromAllDrives': 'true',
    });
    final response = await client.get(
      uri,
      headers: {'Authorization': 'Bearer $token'},
    );
    if (response.statusCode != 200) {
      throw _error(response.statusCode, response.body);
    }
    final files =
        (jsonDecode(response.body) as Map<String, dynamic>)['files'] as List? ??
        [];
    for (final item in files) {
      final file = DriveFileResult.fromJson(Map<String, dynamic>.from(item));
      if (file.parents.contains(parentId)) return file;
    }
    return null;
  }

  Future<DriveFileResult> upload(
    String token,
    ExportJob job, {
    required Future<void> Function(Uri) onSession,
  }) async {
    if (job.folderId != teamFolderId) {
      throw const DriveUploadException('FOLDER_MISMATCH');
    }
    if (job.uploadParentId.isEmpty) {
      throw const DriveUploadException('PATTERN_FOLDER_UNRESOLVED');
    }
    final zip = File(job.localZipPath);
    if (!await zip.exists() || zip.uri.pathSegments.last != job.filename) {
      throw const DriveUploadException('LOCAL_ZIP_MISSING');
    }
    final length = await zip.length();
    final uri = Uri.https('www.googleapis.com', '/upload/drive/v3/files', {
      'uploadType': 'resumable',
      'supportsAllDrives': 'true',
      'fields': _fields,
    });
    final metadata = jsonEncode({
      'name': job.filename,
      'mimeType': 'application/zip',
      'parents': [job.uploadParentId],
      'appProperties': {'export_id': job.exportId},
    });
    final init = await client
        .post(
          uri,
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json; charset=UTF-8',
            'X-Upload-Content-Type': 'application/zip',
            'X-Upload-Content-Length': '$length',
          },
          body: metadata,
        )
        .timeout(const Duration(seconds: 30));
    if (init.statusCode != 200 && init.statusCode != 201) {
      throw _error(init.statusCode, init.body);
    }
    final location = init.headers['location'];
    final session = location == null ? null : Uri.tryParse(location);
    _validateSession(session);
    await onSession(session!);
    try {
      return await _sendRemaining(token, job, session, zip, 0, length);
    } on DriveUploadException catch (e) {
      if (e.code == 'RESUME_REQUIRED') return resume(token, job, session);
      rethrow;
    }
  }

  Future<DriveFileResult> resume(
    String token,
    ExportJob job,
    Uri session,
  ) async {
    _validateSession(session);
    final zip = File(job.localZipPath);
    if (!await zip.exists()) {
      throw const DriveUploadException('LOCAL_ZIP_MISSING');
    }
    final length = await zip.length();
    final probe = http.Request('PUT', session)
      ..headers['Authorization'] = 'Bearer $token'
      ..headers['Content-Range'] = 'bytes */$length';
    final response = await client
        .send(probe)
        .timeout(const Duration(seconds: 30));
    final body = await response.stream.bytesToString();
    if (response.statusCode == 200 || response.statusCode == 201) {
      return _confirmed(job, body);
    }
    if (response.statusCode != 308) {
      throw _error(response.statusCode, body, remoteMayExist: true);
    }
    final range = response.headers['range'];
    final end = range == null
        ? -1
        : int.tryParse(
                RegExp(r'bytes=0-(\d+)').firstMatch(range)?.group(1) ?? '',
              ) ??
              -1;
    if (end + 1 >= length) {
      throw const DriveUploadException(
        'REMOTE_STATUS_UNCONFIRMED',
        remoteMayExist: true,
      );
    }
    return _sendRemaining(token, job, session, zip, end + 1, length);
  }

  Future<DriveFileResult> _sendRemaining(
    String token,
    ExportJob job,
    Uri session,
    File zip,
    int offset,
    int length,
  ) async {
    final request = http.StreamedRequest('PUT', session)
      ..headers['Authorization'] = 'Bearer $token'
      ..headers['Content-Type'] = 'application/zip'
      ..headers['Content-Range'] = 'bytes $offset-${length - 1}/$length'
      ..contentLength = length - offset;
    final responseFuture = client
        .send(request)
        .timeout(const Duration(minutes: 5));
    try {
      await request.sink.addStream(zip.openRead(offset));
      await request.sink.close();
      final response = await responseFuture;
      final body = await response.stream.bytesToString();
      if (response.statusCode == 200 || response.statusCode == 201) {
        return _confirmed(job, body);
      }
      if (response.statusCode == 308) {
        throw const DriveUploadException(
          'RESUME_REQUIRED',
          remoteMayExist: true,
        );
      }
      throw _error(response.statusCode, body, remoteMayExist: true);
    } on DriveUploadException {
      rethrow;
    } catch (_) {
      throw const DriveUploadException(
        'UPLOAD_RESPONSE_UNKNOWN',
        remoteMayExist: true,
      );
    }
  }

  DriveFileResult _confirmed(ExportJob job, String body) {
    final file = DriveFileResult.fromJson(
      jsonDecode(body) as Map<String, dynamic>,
    );
    if (file.id.isEmpty ||
        file.name != job.filename ||
        !file.parents.contains(job.uploadParentId)) {
      throw const DriveUploadException(
        'REMOTE_RESPONSE_MISMATCH',
        remoteMayExist: true,
      );
    }
    return file;
  }

  void _validateSession(Uri? session) {
    if (session == null ||
        session.scheme != 'https' ||
        session.host != 'www.googleapis.com') {
      throw const DriveUploadException(
        'INVALID_UPLOAD_SESSION',
        remoteMayExist: true,
      );
    }
  }

  DriveUploadException _error(
    int status,
    String body, {
    bool remoteMayExist = false,
  }) {
    var reason = '';
    try {
      final error =
          (jsonDecode(body) as Map<String, dynamic>)['error']
              as Map<String, dynamic>?;
      final errors = error?['errors'] as List?;
      if (errors != null && errors.isNotEmpty) {
        reason =
            (errors.first as Map<String, dynamic>)['reason']?.toString() ?? '';
      }
    } catch (_) {
      /* Do not expose response bodies or tokens. */
    }
    if (reason == 'appNotAuthorizedToFile') {
      return DriveUploadException(
        'FOLDER_APP_APPROVAL_REQUIRED',
        remoteMayExist: remoteMayExist,
      );
    }
    if (status == 401) {
      return DriveUploadException(
        'AUTH_EXPIRED',
        remoteMayExist: remoteMayExist,
      );
    }
    if (status == 404) {
      return DriveUploadException(
        'FOLDER_NOT_FOUND',
        remoteMayExist: remoteMayExist,
      );
    }
    if (status == 403) {
      return DriveUploadException(
        'FOLDER_WRITE_DENIED',
        remoteMayExist: remoteMayExist,
      );
    }
    if (status == 429 || status >= 500) {
      return DriveUploadException(
        'RETRYABLE_NETWORK',
        remoteMayExist: remoteMayExist,
      );
    }
    return DriveUploadException(
      'DRIVE_HTTP_$status',
      remoteMayExist: remoteMayExist,
    );
  }
}
