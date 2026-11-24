import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'capture.dart';
import 'enrollment_capture.dart';
import 'enrollment_repository.dart';
import 'login_screen.dart';
import 'model.dart';
import 'pattern_board.dart';
import 'share_origin.dart';
import 'storage.dart';
import 'training_import.dart';

const _violet = Color(0xff6847e8);
const _ink = Color(0xff201957);

String _date(DateTime value) {
  final local = value.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

String _errorText(Object error) => error
    .toString()
    .replaceFirst('Bad state: ', '')
    .replaceFirst('ArgumentError: ', '')
    .replaceFirst('Exception: ', '');

EnrollmentRecord? _recordAt(EnrollmentProfile user, int session, int attempt) {
  for (final record in user.records) {
    if (record.sessionIndex == session && record.attemptIndex == attempt) {
      return record;
    }
  }
  return null;
}

class EnrollmentHome extends StatefulWidget {
  const EnrollmentHome({super.key});

  @override
  State<EnrollmentHome> createState() => _EnrollmentHomeState();
}

class _EnrollmentHomeState extends State<EnrollmentHome> {
  EnrollmentRepository? repository;
  String? deviceId;
  List<EnrollmentProfile> users = const [];
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final storage =
          SessionStorage(Directory('${dir.path}/pattern_sensor_collector'));
      final identity = await storage.ensureDeviceIdentity();
      final repo = EnrollmentRepository(storage);
      final all = await repo.getUsers();
      if (!mounted) return;
      setState(() {
        repository = repo;
        deviceId = identity.uid;
        users = all;
        error = null;
      });
    } catch (e) {
      if (mounted) setState(() => error = _errorText(e));
    }
  }

  Future<void> _refresh() async {
    final repo = repository;
    if (repo == null) return _load();
    try {
      final all = await repo.getUsers();
      if (mounted) setState(() => users = all);
    } catch (e) {
      if (mounted) setState(() => error = _errorText(e));
    }
  }

  Future<void> _register() async {
    final repo = repository, id = deviceId;
    if (repo == null || id == null) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => RegistrationFlowScreen(repository: repo, deviceId: id),
      ),
    );
    if (mounted) await _refresh();
  }

  Future<void> _login() async {
    final repo = repository;
    if (repo == null) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
          builder: (_) => LoginScreen(repository: repo, deviceId: deviceId)),
    );
    if (mounted) await _refresh();
  }

  Future<void> _manage() async {
    final repo = repository, id = deviceId;
    if (repo == null || id == null) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => UserManagementScreen(repository: repo, deviceId: id),
      ),
    );
    if (mounted) await _refresh();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('MotionPrint'),
          actions: [
            IconButton(
              tooltip: '사용자 관리',
              iconSize: 20,
              icon: const Icon(Icons.settings_outlined),
              onPressed: repository == null ? null : _manage,
            ),
          ],
        ),
        body: SafeArea(
          child: repository == null && error == null
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.all(24),
                  children: [
                    const SizedBox(height: 50),
                    const Icon(Icons.grid_on_rounded, size: 64, color: _violet),
                    const SizedBox(height: 24),
                    const Text(
                      '패턴과 움직임 인증',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 25,
                        fontWeight: FontWeight.bold,
                        color: _ink,
                      ),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '등록할 때 패턴을 설정하고 휴대폰의 가속도·자이로 원본 데이터를 '
                      '두 차례에 걸쳐 5회씩 수집합니다. 로그인에 성공할 때마다 데이터가 '
                      '40개까지 쌓이고, 40개가 되면 행동 모델을 학습해 그다음 로그인부터 '
                      '패턴 확인 뒤 행동 인증(2단계)을 적용합니다.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 36),
                    FilledButton(
                      onPressed: repository == null ? null : _register,
                      child: const Text('사용자 등록'),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: repository == null ? null : _login,
                      style: OutlinedButton.styleFrom(
                        minimumSize: const Size(double.infinity, 52),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text('로그인'),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      '등록 중 ${users.where((u) => !u.isComplete).length}명 · '
                      '등록 완료 ${users.where((u) => u.isComplete).length}명',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.black54),
                    ),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: () => Navigator.push<void>(
                        context,
                        MaterialPageRoute(
                            builder: (_) => const PlannedFeaturesScreen()),
                      ),
                      child: const Text('향후 기능 (준비 중)'),
                    ),
                    if (error != null) ...[
                      const SizedBox(height: 20),
                      Text(error!, style: const TextStyle(color: Colors.red)),
                      TextButton(onPressed: _load, child: const Text('다시 시도')),
                    ],
                  ],
                ),
        ),
      );
}

class UserManagementScreen extends StatefulWidget {
  final EnrollmentRepository repository;
  final String deviceId;
  const UserManagementScreen({
    super.key,
    required this.repository,
    required this.deviceId,
  });

  @override
  State<UserManagementScreen> createState() => _UserManagementScreenState();
}

class _UserManagementScreenState extends State<UserManagementScreen> {
  List<EnrollmentProfile>? users;
  String? error;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final all = await widget.repository.getUsers();
      if (mounted) {
        setState(() {
          users = all;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = _errorText(e));
    }
  }

  Future<void> _open(String userId) async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => UserProfileScreen(
          repository: widget.repository,
          deviceId: widget.deviceId,
          userId: userId,
        ),
      ),
    );
    if (mounted) await _reload();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('사용자 관리')),
        body: SafeArea(
          child: users == null && error == null
              ? const Center(child: CircularProgressIndicator())
              : error != null
                  ? Center(child: Text(error!))
                  : users!.isEmpty
                      ? const Center(child: Text('등록된 사용자가 없습니다'))
                      : RefreshIndicator(
                          onRefresh: _reload,
                          child: ListView.builder(
                            padding: const EdgeInsets.all(16),
                            itemCount: users!.length,
                            itemBuilder: (context, index) {
                              final user = users![index];
                              return Card(
                                child: ListTile(
                                  title: Text(
                                      '${user.displayName} · ${user.userId}'),
                                  subtitle: Text(
                                    '${user.isComplete ? '등록 완료' : '등록 중'} · '
                                    '${user.totalCount}/10\n'
                                    '1차 ${user.session1Count}/5 · '
                                    '2차 ${user.session2Count}/5 · 모델 ${user.modelStatus}',
                                  ),
                                  isThreeLine: true,
                                  trailing: const Icon(Icons.chevron_right),
                                  onTap: () => _open(user.userId),
                                ),
                              );
                            },
                          ),
                        ),
        ),
      );
}

class UserProfileScreen extends StatefulWidget {
  final EnrollmentRepository repository;
  final String deviceId, userId;
  const UserProfileScreen({
    super.key,
    required this.repository,
    required this.deviceId,
    required this.userId,
  });

  @override
  State<UserProfileScreen> createState() => _UserProfileScreenState();
}

class _UserProfileScreenState extends State<UserProfileScreen> {
  EnrollmentProfile? profile;
  String? error;
  String? importProgress;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final user = await widget.repository.getUser(widget.userId);
      if (mounted) {
        setState(() {
          profile = user;
          error = user == null ? '사용자를 찾을 수 없습니다.' : null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => error = _errorText(e));
    }
  }

  Future<void> _resume() async {
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => RegistrationFlowScreen(
          repository: widget.repository,
          deviceId: widget.deviceId,
          initialUserId: widget.userId,
        ),
      ),
    );
    if (mounted) await _reload();
  }

  /// v3.1: research-collector ZIPs chosen by the user in the system picker.
  Future<void> _importZips() async {
    if (importProgress != null) return;
    final List<PickedZip> picked;
    try {
      picked = await ZipPicker().pick();
    } catch (e) {
      if (mounted) _showMessage('파일을 열 수 없습니다', _errorText(e));
      return;
    }
    if (picked.isEmpty || !mounted) return;
    final lines = <String>[];
    var imported = 0, mismatch = 0, duplicate = 0, failed = 0;
    for (var i = 0; i < picked.length; i++) {
      final zip = picked[i];
      setState(() => importProgress = '가져오는 중 ${i + 1}/${picked.length}');
      final file = File(zip.path);
      try {
        final result = await widget.repository.importTrainingZip(
          widget.userId,
          await file.readAsBytes(),
          sourceName: zip.name,
        );
        imported += result.imported;
        mismatch += result.patternMismatch;
        duplicate += result.duplicate;
        lines.add('${zip.name}: ${result.imported}회 추가'
            '${result.patternMismatch > 0 ? ' · 패턴 다름 ${result.patternMismatch}' : ''}'
            '${result.duplicate > 0 ? ' · 중복 ${result.duplicate}' : ''}'
            '${result.missingSensor > 0 ? ' · 센서 없음 ${result.missingSensor}' : ''}');
        if (result.autoTrained != null) {
          lines.add('유효 데이터가 $validDataTarget개가 되어 행동 인증 모델을 자동으로 '
              '학습했습니다(${result.autoTrained!.trainedWithCount}개).');
        } else if (result.autoTrainError != null) {
          lines.add('유효 데이터가 $validDataTarget개가 됐지만 모델 자동 학습에 실패했습니다. '
              '모델 학습을 직접 눌러 주세요.');
        }
      } catch (e) {
        failed++;
        lines.add('${zip.name}: 실패 (${_errorText(e)})');
      } finally {
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
    }
    if (!mounted) return;
    setState(() => importProgress = null);
    await _reload();
    if (!mounted) return;
    _showMessage(
      '학습 데이터 가져오기',
      '추가 $imported회 · 패턴 다름 $mismatch회 · 중복 $duplicate회'
          '${failed > 0 ? ' · 실패 파일 $failed개' : ''}\n\n${lines.join('\n')}',
    );
  }

  Future<void> _train() async {
    if (importProgress != null) return;
    setState(() => importProgress = '모델 학습 중…');
    try {
      final info = await widget.repository.trainModel(widget.userId);
      if (!mounted) return;
      setState(() => importProgress = null);
      await _reload();
      if (!mounted) return;
      _showMessage(
        '모델 학습 완료 (프로토타입)',
        '학습 데이터 ${info.trainedWithCount}개 '
            '(등록 ${info.enrollmentCount} · 로그인 ${info.loginCount} · '
            '가져온 데이터 ${info.importedCount})'
            '${info.availableCount > info.trainedWithCount ? ' · 유효 데이터 ${info.availableCount}개 중 먼저 들어온 ${info.trainedWithCount}개' : ''}'
            '${info.skipped > 0 ? ' · 제외 ${info.skipped}개' : ''}\n'
            '임계값 ${info.threshold.toStringAsFixed(4)}\n\n'
            '행동 인증(2단계)은 유효 데이터가 $validDataTarget개 이상일 때 적용됩니다. '
            '이 사용자의 처음 40개로 모델을 만들었습니다. '
            '임계값은 v4.2 연구에서 미리 정한 고정값입니다.',
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => importProgress = null);
      _showMessage('모델을 학습하지 못했습니다', _errorText(e));
    }
  }

  Future<void> _exportTrainingData() async {
    if (importProgress != null) return;
    setState(() => importProgress = '학습 데이터 ZIP 생성 중…');
    try {
      final file =
          await widget.repository.exportModelTrainingData(widget.userId);
      if (!mounted) return;
      setState(() => importProgress = null);
      await SharePlus.instance.share(ShareParams(
        files: [XFile(file.path)],
        text: '${widget.userId} 행동 모델 학습 데이터 $validDataTarget개',
        sharePositionOrigin: shareSheetOrigin(context),
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() => importProgress = null);
      _showMessage('학습 데이터를 내보내지 못했습니다', _errorText(e));
    }
  }

  Future<void> _delete() async {
    final user = profile;
    if (user == null) return;
    final typed = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('사용자 삭제'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('${user.displayName}(${user.userId})의 프로필, 패턴 검증 정보, '
                  '등록 원본 기록 ${user.records.length}개, 가져온 학습 데이터 '
                  '${user.importedTrialCount}회를 모두 삭제합니다. 되돌릴 수 없습니다.'),
              const SizedBox(height: 14),
              Text('확인을 위해 사용자 ID(${user.userId})를 입력해 주세요.'),
              TextField(
                controller: typed,
                autocorrect: false,
                onChanged: (_) => setDialogState(() {}),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('취소'),
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              onPressed: typed.text.trim() == user.userId
                  ? () => Navigator.pop(context, true)
                  : null,
              child: const Text('삭제'),
            ),
          ],
        ),
      ),
    );
    typed.dispose();
    if (confirmed != true || !mounted) return;
    try {
      await widget.repository.deleteUser(user.userId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${user.userId} 사용자를 삭제했습니다.')),
      );
      Navigator.pop(context);
    } catch (e) {
      if (mounted) _showMessage('삭제하지 못했습니다', _errorText(e));
    }
  }

  void _showMessage(String title, String body) => showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(child: Text(body)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('확인'),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final user = profile;
    return Scaffold(
      appBar: AppBar(title: const Text('사용자 프로필')),
      body: SafeArea(
        child: user == null
            ? Center(
                child: error == null
                    ? const CircularProgressIndicator()
                    : Text(error!),
              )
            : ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(user.displayName,
                              style: Theme.of(context).textTheme.headlineSmall),
                          const SizedBox(height: 8),
                          Text('사용자 ID: ${user.userId}'),
                          Text('등록 상태: ${user.isComplete ? '등록 완료' : '등록 중'}'),
                          Text('패턴 설정: ${user.hasPattern ? '완료' : '진행 전'}'),
                          Text('등록 일시: ${_date(user.createdAt)}'),
                          Text('모델 상태: ${user.modelStatus}'),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('학습 데이터 수집',
                              style: TextStyle(fontWeight: FontWeight.bold)),
                          Text('1차 세션: ${user.session1Count} / 5'),
                          Text('2차 세션: ${user.session2Count} / 5'),
                          Text('합계: ${user.totalCount} / 10'),
                          Text('저장된 원본 기록: ${user.records.length}개'),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text('가져온 학습 데이터',
                              style: TextStyle(fontWeight: FontWeight.bold)),
                          Text('${user.importedTrialCount}회 '
                              '(zip ${user.importBatchCount}개 · 등록 10회와 별도)'),
                          const SizedBox(height: 4),
                          const Text(
                            '연구용 수집 앱에서 내보낸 zip 중 등록 패턴과 같은 시도만 앱 내부 저장소에 보관합니다.',
                            style:
                                TextStyle(color: Colors.black54, fontSize: 13),
                          ),
                          const SizedBox(height: 10),
                          if (importProgress != null) ...[
                            const LinearProgressIndicator(),
                            const SizedBox(height: 6),
                            Text(importProgress!, textAlign: TextAlign.center),
                          ] else
                            OutlinedButton.icon(
                              onPressed: user.hasPattern ? _importZips : null,
                              icon: const Icon(Icons.upload_file),
                              label: const Text('학습 데이터 가져오기 (zip)'),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text('행동 인증 모델 (프로토타입)',
                              style: TextStyle(fontWeight: FontWeight.bold)),
                          Text(user.model == null
                              ? (user.validDataCount >= validDataTarget
                                  ? '미학습 · 유효 데이터가 $validDataTarget개 이상이라 '
                                      '모델을 학습하기 전에는 로그인할 수 없습니다'
                                  : '미학습 · 유효 데이터가 $validDataTarget개가 되면 자동으로 학습합니다')
                              : '학습됨 (${user.model!.trigger == 'auto' ? '유효 데이터 $validDataTarget개 도달 시 자동 학습' : '수동 학습'}) · '
                                  '${_date(user.model!.trainedAt)}\n'
                                  '학습 데이터 ${user.model!.trainedWithCount}개 '
                                  '(등록 ${user.model!.enrollmentCount} · '
                                  '로그인 ${user.model!.loginCount} · '
                                  '가져온 데이터 ${user.model!.importedCount})'
                                  '${user.model!.availableCount > user.model!.trainedWithCount ? ' · 유효 데이터 ${user.model!.availableCount}개 중 먼저 들어온 ${user.model!.trainedWithCount}개' : ''}\n'
                                  '${user.validDataCount >= validDataTarget ? '로그인 시 패턴 확인 뒤 행동 인증(2단계) 적용' : '유효 데이터 $validDataTarget개부터 행동 인증(2단계) 적용 · 지금은 패턴만 확인'}'),
                          const SizedBox(height: 4),
                          Text(
                            'v4.2 가중 거리 모델은 입력 전 기준선을 포함한 새 기록을 사용합니다. '
                            '이 사용자 기록 40개가 모이면 40개 전체로 학습합니다. '
                            '임계값은 v4.2 연구 고정값입니다. 이전 방식의 기록은 새 모델에 사용할 수 없습니다.',
                            style: const TextStyle(
                                color: Colors.black54, fontSize: 13),
                          ),
                          const SizedBox(height: 10),
                          OutlinedButton.icon(
                            onPressed: user.hasPattern && importProgress == null
                                ? _train
                                : null,
                            icon: const Icon(Icons.model_training),
                            label:
                                Text(user.model == null ? '모델 학습' : '모델 다시 학습'),
                          ),
                          OutlinedButton.icon(
                            onPressed: user.model?.trainedWithCount ==
                                        validDataTarget &&
                                    importProgress == null
                                ? _exportTrainingData
                                : null,
                            icon: const Icon(Icons.download),
                            label: Text('학습 데이터 $validDataTarget개 ZIP 내보내기'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text('인증 데이터 축적',
                              style: TextStyle(fontWeight: FontWeight.bold)),
                          Text(
                              '유효 데이터 ${user.validDataCount} / $validDataTarget '
                              '(등록 ${user.totalCount} · 로그인 ${user.loginRecordIds.length} · '
                              '가져온 데이터 ${user.importedTrialCount})'),
                          const SizedBox(height: 6),
                          LinearProgressIndicator(
                            value: (user.validDataCount / validDataTarget)
                                .clamp(0.0, 1.0),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            !user.isComplete
                                ? '등록을 마치면 로그인 성공 기록이 학습 데이터로 쌓입니다.'
                                : user.validDataCount < validDataTarget
                                    ? '로그인에 성공할 때마다 그 입력을 학습 데이터로 저장합니다. '
                                        '$validDataTarget개가 되면 모델을 자동으로 학습하고, 그다음 '
                                        '로그인부터 행동 인증(2단계)을 적용합니다.'
                                    : '$validDataTarget개를 채워 더 이상 로그인 기록을 저장하지 않습니다. '
                                        '로그인에는 행동 인증(2단계)이 필요합니다.',
                            style: const TextStyle(
                                color: Colors.black54, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (!user.isComplete) ...[
                    const SizedBox(height: 14),
                    FilledButton(
                        onPressed: _resume, child: const Text('등록 이어서 진행')),
                  ],
                  const SizedBox(height: 22),
                  Text('수집 기록', style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 8),
                  ...List.generate(10, (slot) {
                    final session = slot ~/ 5 + 1;
                    final attempt = slot % 5 + 1;
                    final record = _recordAt(user, session, attempt);
                    return Card(
                      child: ListTile(
                        leading: Icon(
                          record == null
                              ? Icons.radio_button_unchecked
                              : Icons.check_circle,
                          color: record == null ? Colors.grey : Colors.green,
                        ),
                        title: Text(
                          '$session차 · $attempt/5 · '
                          '${record == null ? '미수집' : '저장 성공'}',
                        ),
                        subtitle: record == null
                            ? null
                            : Text('${_date(record.capturedAt)} · '
                                '${record.isTouchBounded ? '터치 구간' : '이전 5초창'}\n'
                                '기록 ID: ${record.recordId}'),
                        isThreeLine: record != null,
                      ),
                    );
                  }),
                  const SizedBox(height: 28),
                  TextButton.icon(
                    style: TextButton.styleFrom(foregroundColor: Colors.red),
                    onPressed: importProgress == null ? _delete : null,
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('사용자 삭제'),
                  ),
                ],
              ),
      ),
    );
  }
}

enum _RegistrationPage {
  info,
  create,
  confirm,
  capture1,
  regrip,
  capture2,
  complete
}

class RegistrationFlowScreen extends StatefulWidget {
  final EnrollmentRepository repository;
  final String deviceId;
  final String? initialUserId;
  const RegistrationFlowScreen({
    super.key,
    required this.repository,
    required this.deviceId,
    this.initialUserId,
  });

  @override
  State<RegistrationFlowScreen> createState() => _RegistrationFlowScreenState();
}

class _RegistrationFlowScreenState extends State<RegistrationFlowScreen> {
  final name = TextEditingController();
  final userId = TextEditingController();
  final capture = EnrollmentCaptureController();
  EnrollmentProfile? profile;
  _RegistrationPage page = _RegistrationPage.info;
  List<int> candidate = const [];
  List<int> confirmation = const [];
  int boardRevision = 0;
  bool busy = false;
  bool loading = false;
  bool needsRetry = false;
  String? feedback;

  bool get _onCapturePage =>
      page == _RegistrationPage.capture1 || page == _RegistrationPage.capture2;

  /// Arms the sensors for the next attempt once the board is on screen.
  /// There is no start button: the attempt begins at the first touch.
  void _scheduleCapture() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_captureTrial());
    });
  }

  @override
  void initState() {
    super.initState();
    capture.addListener(_captureChanged);
    if (widget.initialUserId != null) {
      loading = true;
      _resume();
    }
  }

  void _captureChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    capture.removeListener(_captureChanged);
    capture.dispose();
    name.dispose();
    userId.dispose();
    super.dispose();
  }

  Future<void> _resume() async {
    try {
      final user = await widget.repository.getUser(widget.initialUserId!);
      if (user == null) throw StateError('사용자를 찾을 수 없습니다.');
      if (!mounted) return;
      setState(() {
        profile = user;
        page = switch (user.stage) {
          EnrollmentStage.draft => _RegistrationPage.create,
          EnrollmentStage.collectingSession1 => _RegistrationPage.capture1,
          EnrollmentStage.regripRequired => _RegistrationPage.regrip,
          EnrollmentStage.collectingSession2 => _RegistrationPage.capture2,
          EnrollmentStage.completed => _RegistrationPage.complete,
        };
        loading = false;
      });
      if (_onCapturePage) _scheduleCapture();
    } catch (e) {
      if (mounted) {
        setState(() {
          feedback = _errorText(e);
          loading = false;
        });
      }
    }
  }

  Future<void> _createUser() async {
    if (busy) return;
    setState(() {
      busy = true;
      feedback = null;
    });
    try {
      final user = await widget.repository.createUser(
        userId: userId.text.trim(),
        displayName: name.text.trim(),
      );
      if (!mounted) return;
      setState(() {
        profile = user;
        page = _RegistrationPage.create;
      });
    } catch (e) {
      if (mounted) setState(() => feedback = _errorText(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void _nextToConfirm() {
    if (candidate.length < 3) return;
    setState(() {
      page = _RegistrationPage.confirm;
      confirmation = const [];
      feedback = null;
      boardRevision++;
    });
  }

  Future<void> _confirmPattern() async {
    if (busy || profile == null || confirmation.length < 3) return;
    if (!listEquals(candidate, confirmation)) {
      setState(() {
        confirmation = const [];
        feedback = '패턴이 일치하지 않습니다. 다시 그려 주세요.';
        boardRevision++;
      });
      return;
    }
    setState(() {
      busy = true;
      feedback = null;
    });
    try {
      final user =
          await widget.repository.confirmPattern(profile!.userId, candidate);
      if (!mounted) return;
      setState(() {
        profile = user;
        candidate = const [];
        confirmation = const [];
        page = _RegistrationPage.capture1;
      });
      _scheduleCapture();
    } catch (e) {
      if (mounted) setState(() => feedback = _errorText(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _captureTrial() async {
    final user = profile;
    if (user == null || !_onCapturePage || busy || capture.isBusy) return;
    final session = page == _RegistrationPage.capture1 ? 1 : 2;
    final index =
        session == 1 ? user.session1Count + 1 : user.session2Count + 1;
    if (index > 5) return;
    setState(() => needsRetry = false);
    final TrialRecord trial;
    try {
      trial = await capture.next(
        userId: user.userId,
        sessionId: enrollmentSessionId(user.userId, session),
        attemptIndex: index,
        deviceId: widget.deviceId,
      );
    } catch (e) {
      // Sensor start failure, app paused, or screen closed: wait for the
      // user to retry explicitly instead of re-arming in a loop.
      if (mounted) {
        setState(() {
          feedback = '이번 입력은 집계되지 않았습니다. ${_errorText(e)}';
          needsRetry = true;
        });
      }
      return;
    }
    if (!mounted) return;
    setState(() => busy = true);
    try {
      final quality = assess(trial);
      if (trial.captureError != null) {
        setState(() => feedback = _captureFailure(trial.captureError!));
      } else if (!await widget.repository
          .matchesPattern(user.userId, trial.actual)) {
        setState(() => feedback = '등록한 패턴과 다릅니다. 다시 그려 주세요.');
      } else if (!quality.eligible) {
        setState(() => feedback = _captureFailure(quality.reason));
      } else {
        final saved =
            await widget.repository.saveCapture(user.userId, session, trial);
        if (!mounted) return;
        setState(() {
          profile = saved;
          feedback = '저장 완료 · ${saved.totalCount}/10';
          if (saved.isComplete) {
            page = _RegistrationPage.complete;
          } else if (session == 1 && saved.session1Count == 5) {
            page = _RegistrationPage.regrip;
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => feedback = '이번 입력은 집계되지 않았습니다. ${_errorText(e)}');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
    if (mounted && _onCapturePage) _scheduleCapture();
  }

  static String _captureFailure(String reason) {
    final message = switch (reason) {
      'touch_cancelled' => '터치가 취소됐습니다.',
      'multitouch' => '두 손가락 이상이 닿았습니다. 한 손가락으로 그려 주세요.',
      'left_board' => '손가락이 패턴 영역 밖으로 나갔습니다.',
      'multiple_strokes' => '손을 떼지 말고 한 번에 이어서 그려 주세요.',
      'start_outside_node' => '첫 터치는 점 위에서 시작해 주세요.',
      'sensor_coverage' ||
      'TOUCH_WINDOW_SENSOR_GAP' ||
      'segment_sensor_count' ||
      'SENSOR_DRAIN_TIMEOUT' =>
        '센서 데이터가 충분히 기록되지 않았습니다.',
      _ => '입력 또는 센서 기록이 유효하지 않습니다.',
    };
    return '이번 입력은 집계되지 않았습니다. $message 다시 그려 주세요. (사유: $reason)';
  }

  Future<void> _acknowledgeRegrip() async {
    final user = profile;
    if (user == null || busy) return;
    setState(() => busy = true);
    try {
      final updated = await widget.repository.acknowledgeRegrip(user.userId);
      if (!mounted) return;
      setState(() {
        profile = updated;
        page = _RegistrationPage.capture2;
        feedback = null;
      });
      _scheduleCapture();
    } catch (e) {
      if (mounted) setState(() => feedback = _errorText(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void _openProfile() {
    final user = profile;
    if (user == null || !user.isComplete) return;
    Navigator.pushReplacement<void, void>(
      context,
      MaterialPageRoute(
        builder: (_) => UserProfileScreen(
          repository: widget.repository,
          deviceId: widget.deviceId,
          userId: user.userId,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final title = switch (page) {
      _RegistrationPage.info => '사용자 정보 입력',
      _RegistrationPage.create => '패턴 생성',
      _RegistrationPage.confirm => '패턴 재확인',
      _RegistrationPage.capture1 => '1차 데이터 수집',
      _RegistrationPage.regrip => '파지 변경',
      _RegistrationPage.capture2 => '2차 데이터 수집',
      _RegistrationPage.complete => '등록 완료',
    };
    return PopScope(
      // Leaving is allowed while the board is only armed; it is blocked while
      // a stroke is being recorded or a result is being saved.
      canPop: !busy &&
          capture.state != EnrollmentCaptureState.recording &&
          capture.state != EnrollmentCaptureState.finishing,
      child: Scaffold(
        appBar: AppBar(title: Text(title)),
        body: SafeArea(
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.all(20),
                  children: [
                    // On capture pages feedback is shown below the board so the
                    // board does not move between attempts.
                    if (feedback != null && !_onCapturePage) ...[
                      Card(
                        color: const Color(0xfffff3f0),
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Text(feedback!),
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    switch (page) {
                      _RegistrationPage.info => _info(),
                      _RegistrationPage.create => _patternStep(
                          '3×3 점을 이어서 나만의 패턴을 그려 주세요.',
                          candidate,
                          (nodes) => setState(() => candidate = nodes),
                          '다음',
                          candidate.length >= 3 && !busy
                              ? _nextToConfirm
                              : null,
                        ),
                      _RegistrationPage.confirm => _patternStep(
                          '방금 만든 패턴을 다시 그려 주세요.',
                          confirmation,
                          (nodes) => setState(() => confirmation = nodes),
                          '패턴 확인',
                          confirmation.length >= 3 && !busy
                              ? _confirmPattern
                              : null,
                        ),
                      _RegistrationPage.capture1 => _captureStep(1),
                      _RegistrationPage.regrip => _regrip(),
                      _RegistrationPage.capture2 => _captureStep(2),
                      _RegistrationPage.complete => _complete(),
                    },
                  ],
                ),
        ),
      ),
    );
  }

  Widget _info() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('이름과 고유 사용자 ID를 입력해 주세요.'),
          const SizedBox(height: 20),
          TextField(
            controller: name,
            textInputAction: TextInputAction.next,
            decoration: const InputDecoration(
                labelText: '이름', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: userId,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: '사용자 ID',
              helperText: '영문, 숫자, _ 또는 - 사용',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 22),
          FilledButton(
            onPressed: busy ? null : _createUser,
            child: const Text('다음'),
          ),
        ],
      );

  Widget _patternStep(
    String instruction,
    List<int> nodes,
    ValueChanged<List<int>> onPattern,
    String buttonText,
    VoidCallback? next,
  ) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(instruction, style: const TextStyle(fontSize: 17, color: _ink)),
          const SizedBox(height: 10),
          const Text('실제 기기 잠금 패턴은 사용하지 마세요.'),
          const SizedBox(height: 20),
          PatternInputBoard(
              key: ValueKey('${page.name}-$boardRevision'),
              onPattern: onPattern),
          const SizedBox(height: 14),
          Text(nodes.length >= 3
              ? '${nodes.length}개 점 입력됨'
              : '3개 이상 점을 연결해 주세요.'),
          const SizedBox(height: 22),
          FilledButton(onPressed: next, child: Text(buttonText)),
        ],
      );

  Widget _captureStep(int session) {
    final user = profile;
    if (user == null) return const Text('사용자 정보를 불러올 수 없습니다.');
    final count = session == 1 ? user.session1Count : user.session2Count;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '$session차 수집 · $count/5',
          style:
              Theme.of(context).textTheme.headlineSmall?.copyWith(color: _ink),
        ),
        const SizedBox(height: 8),
        const Text('등록한 패턴을 그려 주세요. 첫 터치부터 손을 뗄 때까지 센서가 기록됩니다.'),
        const SizedBox(height: 8),
        const Text('패턴은 화면에 표시하지 않습니다. 한 손가락으로 한 번에 그려 주세요.'),
        const SizedBox(height: 20),
        TouchCaptureBoard(capture: capture),
        const SizedBox(height: 14),
        Text(
          busy
              ? '저장 확인 중…'
              : switch (capture.state) {
                  EnrollmentCaptureState.preparing => '센서 준비 중…',
                  EnrollmentCaptureState.ready => '준비됨 · 패턴을 그려 주세요',
                  EnrollmentCaptureState.recording => '기록 중 · 손을 떼면 끝납니다',
                  EnrollmentCaptureState.finishing => '기록 마무리 중…',
                  EnrollmentCaptureState.idle =>
                    needsRetry ? '수집이 멈췄습니다' : '대기 중',
                },
          textAlign: TextAlign.center,
          style: const TextStyle(
              fontSize: 20, fontWeight: FontWeight.bold, color: _violet),
        ),
        if (feedback != null) ...[
          const SizedBox(height: 12),
          Card(
            color: const Color(0xfffff3f0),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Text(feedback!),
            ),
          ),
        ],
        if (needsRetry && !capture.isBusy && !busy) ...[
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: _captureTrial,
            child: const Text('다시 준비'),
          ),
        ],
        const SizedBox(height: 10),
        Text('전체 저장 완료 ${user.totalCount}/10', textAlign: TextAlign.center),
      ],
    );
  }

  Widget _regrip() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 80),
          const Icon(Icons.phone_android, size: 72, color: _violet),
          const SizedBox(height: 24),
          const Text(
            '휴대폰을 내려놓았다가 다시 잡아 주세요',
            textAlign: TextAlign.center,
            style: TextStyle(
                fontSize: 23, fontWeight: FontWeight.bold, color: _ink),
          ),
          const SizedBox(height: 12),
          const Text('1차 수집 5회가 저장됐습니다. 다시 잡은 뒤 2차 수집을 진행합니다.',
              textAlign: TextAlign.center),
          const SizedBox(height: 36),
          FilledButton(
              onPressed: busy ? null : _acknowledgeRegrip,
              child: const Text('계속')),
        ],
      );

  Widget _complete() {
    final user = profile;
    if (user == null || !user.isComplete) {
      return const Text('저장된 10회 기록을 확인하는 중입니다.');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 70),
        const Icon(Icons.check_circle, size: 80, color: Colors.green),
        const SizedBox(height: 22),
        const Text(
          '등록 완료',
          textAlign: TextAlign.center,
          style:
              TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: _ink),
        ),
        const SizedBox(height: 10),
        Text('${user.displayName}님의 원본 수집 기록 10회가 저장됐습니다.',
            textAlign: TextAlign.center),
        const SizedBox(height: 36),
        FilledButton(onPressed: _openProfile, child: const Text('프로필 보기')),
      ],
    );
  }
}

/// 3×3 board backed by the native touch view: sensors are recorded from the
/// first touch down to the touch up (v3). Shared by enrollment and login.
class TouchCaptureBoard extends StatelessWidget {
  final EnrollmentCaptureController capture;
  const TouchCaptureBoard({super.key, required this.capture});

  @override
  Widget build(BuildContext context) {
    final size = min(MediaQuery.sizeOf(context).width - 40, 390.0);
    return Center(
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          children: [
            CustomPaint(
              size: Size(size, size),
              painter: BoardPainter(
                target: const [],
                actual: capture.tracker?.visits.map((v) => v.node).toList() ??
                    const [],
              ),
            ),
            if (Platform.isAndroid)
              // The board sits inside a ListView: claim every gesture so a
              // vertical stroke is not taken over by scrolling (which would
              // cancel the touch mid-pattern).
              AndroidView(
                viewType: 'pattern_sensor/touch_view',
                gestureRecognizers: {
                  Factory<OneSequenceGestureRecognizer>(
                      () => EagerGestureRecognizer()),
                },
              )
            else if (Platform.isIOS)
              const UiKitView(viewType: 'pattern_sensor/touch_view'),
          ],
        ),
      ),
    );
  }
}

/// Uses the same board painter and pattern normalization as the collector.
class PatternInputBoard extends StatefulWidget {
  final ValueChanged<List<int>> onPattern;
  const PatternInputBoard({super.key, required this.onPattern});

  @override
  State<PatternInputBoard> createState() => _PatternInputBoardState();
}

class _PatternInputBoardState extends State<PatternInputBoard> {
  List<int> points = const [];
  int? activePointer;
  PatternTracker? drawing;
  double lastEventTime = -1;

  void _accept(PointerEvent event, String type, double size) {
    final tracker = drawing;
    if (tracker == null) return;
    final reportedTime = event.timeStamp.inMicroseconds / 1e6;
    final time = max(reportedTime, lastEventTime + 0.000001);
    lastEventTime = time;
    tracker.accept({
      'type': type,
      'time': time,
      'x': event.localPosition.dx / size,
      'y': event.localPosition.dy / size,
    });
    setState(() => points = tracker.visits.map((visit) => visit.node).toList());
  }

  @override
  Widget build(BuildContext context) {
    final size = min(MediaQuery.sizeOf(context).width - 40, 390.0);
    return Center(
      child: SizedBox(
        width: size,
        height: size,
        child: Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) {
            if (activePointer != null) {
              drawing?.error = 'multitouch';
              return;
            }
            activePointer = event.pointer;
            drawing = PatternTracker();
            lastEventTime = -1;
            _accept(event, 'DOWN', size);
          },
          onPointerMove: (event) {
            if (activePointer == event.pointer) _accept(event, 'MOVE', size);
          },
          onPointerUp: (event) {
            if (activePointer != event.pointer) return;
            _accept(event, 'UP', size);
            activePointer = null;
            final valid = drawing?.error == null && drawing?.end != null;
            widget.onPattern(valid ? List<int>.of(points) : const []);
            drawing = null;
          },
          onPointerCancel: (event) {
            if (activePointer != event.pointer) return;
            activePointer = null;
            drawing = null;
            setState(() => points = const []);
            widget.onPattern(const []);
          },
          child: CustomPaint(
            size: Size(size, size),
            painter: BoardPainter(target: const [], actual: points),
          ),
        ),
      ),
    );
  }
}
