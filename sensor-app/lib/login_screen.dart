import 'dart:async';

import 'package:flutter/material.dart';

import 'behavior_auth.dart';
import 'enrollment_capture.dart';
import 'enrollment_repository.dart';
import 'enrollment_screen.dart';
import 'model.dart';

const _violet = Color(0xff6847e8);
const _ink = Color(0xff201957);

/// Login. Pattern match is the first factor. With [validDataTarget] or more
/// valid data at login start the behavioral second factor is required; if
/// no model is ready the login is held (never downgraded to pattern only).
/// While an enrolled user's valid data is below the target, a successful
/// login capture is stored as training data; reaching the target trains the
/// model once. No lockout runs.
class LoginScreen extends StatefulWidget {
  final EnrollmentRepository repository;
  final String? deviceId;
  const LoginScreen({super.key, required this.repository, this.deviceId});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  List<EnrollmentProfile>? users;
  String? error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final all = await widget.repository.getUsers();
      if (mounted) {
        // Enrolled users, plus users whose model was trained from imported
        // research data (v3.2) without completing in-app enrollment.
        setState(() => users = all
            .where((u) =>
                u.isComplete ||
                u.model != null ||
                u.validDataCount >= validDataTarget)
            .toList());
      }
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('로그인')),
        body: SafeArea(
          child: users == null && error == null
              ? const Center(child: CircularProgressIndicator())
              : error != null
                  ? Center(child: Text(error!))
                  : users!.isEmpty
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(24),
                            child: Text(
                              '로그인할 수 있는 사용자가 없습니다.\n'
                              '사용자 등록을 마치거나 행동 모델을 학습해 주세요.',
                              textAlign: TextAlign.center,
                            ),
                          ),
                        )
                      : ListView(
                          padding: const EdgeInsets.all(16),
                          children: [
                            const Padding(
                              padding: EdgeInsets.fromLTRB(4, 4, 4, 12),
                              child: Text('로그인할 사용자를 선택해 주세요.'),
                            ),
                            for (final user in users!)
                              Card(
                                child: ListTile(
                                  leading: const Icon(Icons.person_outline),
                                  title: Text(user.displayName),
                                  subtitle: Text(user.userId),
                                  trailing: const Icon(Icons.chevron_right),
                                  onTap: () => Navigator.push<void>(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => LoginPatternScreen(
                                        repository: widget.repository,
                                        user: user,
                                        deviceId: widget.deviceId,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
        ),
      );
}

class LoginPatternScreen extends StatefulWidget {
  final EnrollmentRepository repository;
  final EnrollmentProfile user;
  final String? deviceId;
  const LoginPatternScreen({
    super.key,
    required this.repository,
    required this.user,
    this.deviceId,
  });

  @override
  State<LoginPatternScreen> createState() => _LoginPatternScreenState();
}

class _LoginPatternScreenState extends State<LoginPatternScreen> {
  int boardRevision = 0;
  bool checking = false;
  String? feedback;

  /// Latest profile; the phase of each attempt is decided from the valid
  /// data stored before that attempt.
  late EnrollmentProfile profile = widget.user;
  LoginPhase get phase => loginPhaseOf(profile);

  /// The native touch board records the IMU; it is needed for the second
  /// factor and for collecting login data.
  EnrollmentCaptureController? capture;

  @override
  void initState() {
    super.initState();
    if (widget.user.collectsLoginData ||
        loginPhaseOf(widget.user) != LoginPhase.patternOnly) {
      capture = EnrollmentCaptureController()..addListener(_changed);
      _scheduleCapture();
    }
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    capture?.removeListener(_changed);
    capture?.dispose();
    super.dispose();
  }

  void _scheduleCapture() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_captureAttempt());
    });
  }

  /// Pattern-only login (below the target and no data collection).
  Future<void> _onPattern(List<int> nodes) async {
    if (checking) return;
    if (nodes.isEmpty) {
      setState(() {
        feedback = '입력이 취소됐습니다. 한 손가락으로 다시 그려 주세요.';
        boardRevision++;
      });
      return;
    }
    setState(() {
      checking = true;
      feedback = null;
    });
    bool matched;
    try {
      matched =
          await widget.repository.matchesPattern(widget.user.userId, nodes);
    } catch (_) {
      matched = false;
    }
    await _showResult(matched, stage: 1);
    if (mounted) {
      setState(() {
        checking = false;
        boardRevision++;
      });
    }
  }

  /// Login with sensor capture: pattern (first factor), then the behavior
  /// score when a model exists; a successful capture is stored as training
  /// data while the user collects login data.
  Future<void> _captureAttempt() async {
    final controller = capture;
    if (controller == null || controller.isBusy || checking) return;
    final TrialRecord trial;
    try {
      trial = await controller.next(
        userId: widget.user.userId,
        sessionId: loginSessionId(widget.user.userId),
        attemptIndex: 1,
        deviceId: widget.deviceId ?? 'login',
        source: TrialRecord.loginSource,
      );
    } catch (e) {
      if (mounted) {
        setState(() => feedback =
            '입력을 받지 못했습니다. ${e.toString().replaceFirst('Bad state: ', '')}');
      }
      return;
    }
    if (!mounted) return;
    if (trial.captureError != null) {
      setState(() => feedback = '입력이 취소됐습니다. 한 손가락으로 한 번에 다시 그려 주세요.');
      _scheduleCapture();
      return;
    }
    setState(() {
      checking = true;
      feedback = null;
    });
    try {
      final fresh = await widget.repository.getUser(widget.user.userId);
      if (fresh != null) profile = fresh;
    } catch (_) {
      // Keep the last known profile.
    }
    final attemptPhase = phase;
    final collects = profile.collectsLoginData;
    var success = false, held = false;
    String diagnostics;
    String? dataNote;
    final count = '유효 데이터 ${profile.validDataCount}/$validDataTarget';
    try {
      final matched = await widget.repository
          .matchesPattern(widget.user.userId, trial.actual);
      if (!matched) {
        diagnostics = '1단계(패턴) 불일치';
      } else if (attemptPhase == LoginPhase.patternOnly) {
        success = true;
        diagnostics = '1단계 통과 · $count 미만 → 패턴만 확인';
      } else if (attemptPhase == LoginPhase.modelNotReady) {
        held = true;
        diagnostics = '1단계 통과 · $count → 2단계 필요 · 모델 미준비 → 보류';
      } else {
        final decision =
            await widget.repository.verifyBehavior(widget.user.userId, trial);
        success = decision.accepted;
        diagnostics = '1단계 통과 · $count · 2단계 점수 '
            '${decision.score.toStringAsFixed(4)} / 임계값 '
            '${decision.threshold.toStringAsFixed(4)} → '
            '${decision.accepted ? '승인' : '거부'}';
      }
    } on BehaviorFeatureException catch (e) {
      diagnostics = '1단계 통과 · 2단계 특징 계산 실패 ($e)';
    } catch (e) {
      diagnostics = '판정 오류 ($e)';
    }
    if (success && collects) {
      try {
        final saved =
            await widget.repository.saveLoginCapture(widget.user.userId, trial);
        if (saved.autoTrained != null) {
          dataNote = '유효 데이터가 $validDataTarget개가 되어 행동 인증 모델을 '
              '자동으로 학습했습니다(${saved.autoTrained!.trainedWithCount}개). '
              '다음 로그인부터 행동 인증(2단계)이 적용됩니다.';
        } else if (saved.autoTrainError != null) {
          dataNote = '유효 데이터가 $validDataTarget개가 됐지만 v4.2 모델 학습에 실패했습니다. '
              '프로필에서 원인을 확인하고 다시 학습해 주세요.';
          diagnostics += '\n자동 학습 실패: ${saved.autoTrainError}';
        } else if (saved.stored) {
          dataNote = '이번 입력을 학습 데이터로 저장했습니다 '
              '(${saved.validDataCount}/$validDataTarget).';
        }
        diagnostics += '\n학습 데이터: ${saved.stored ? '저장' : '저장 안 함'} · '
            '유효 데이터 ${saved.validDataCount}/$validDataTarget';
      } catch (e) {
        diagnostics += '\n학습 데이터 저장 실패 ($e)';
      }
    }
    await _showResult(success,
        stage: attemptPhase == LoginPhase.patternOnly ? 1 : 2,
        held: held,
        diagnostics: diagnostics,
        dataNote: dataNote);
    try {
      final fresh = await widget.repository.getUser(widget.user.userId);
      if (fresh != null) profile = fresh;
    } catch (_) {
      // Keep the last known profile.
    }
    if (mounted) {
      setState(() => checking = false);
      _scheduleCapture();
    }
  }

  Future<void> _showResult(bool success,
      {required int stage,
      bool held = false,
      String? diagnostics,
      String? dataNote}) async {
    if (!mounted) return;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => AuthResultScreen(
          success: success,
          displayName: widget.user.displayName,
          stage: stage,
          held: held,
          diagnostics: diagnostics,
          dataNote: dataNote,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final controller = capture;
    return Scaffold(
      appBar: AppBar(title: Text('${widget.user.displayName} 로그인')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text('등록한 패턴을 그려 주세요.',
                style: TextStyle(fontSize: 17, color: _ink)),
            const SizedBox(height: 6),
            Text(
              switch (phase) {
                    LoginPhase.behavior =>
                      '패턴 확인(1단계) 뒤 행동 인증(2단계, 프로토타입)을 적용합니다.',
                    LoginPhase.modelNotReady =>
                      '유효 데이터가 $validDataTarget개 이상이라 행동 인증이 필요하지만 '
                          '모델이 준비되지 않아 로그인할 수 없습니다. 프로필에서 모델을 학습해 주세요.',
                    LoginPhase.patternOnly =>
                      '유효 데이터가 $validDataTarget개 미만이라 패턴 확인(1단계)만 적용합니다 '
                          '(${profile.validDataCount}/$validDataTarget).',
                  } +
                  (profile.collectsLoginData
                      ? '\n로그인에 성공하면 이번 입력을 학습 데이터로 저장합니다.'
                      : ''),
              style: const TextStyle(color: Colors.black54),
            ),
            const SizedBox(height: 20),
            if (controller == null)
              AbsorbPointer(
                absorbing: checking,
                child: PatternInputBoard(
                  key: ValueKey('login-$boardRevision'),
                  onPattern: _onPattern,
                ),
              )
            else ...[
              TouchCaptureBoard(capture: controller),
              const SizedBox(height: 12),
              Text(
                checking
                    ? '확인 중…'
                    : switch (controller.state) {
                        EnrollmentCaptureState.preparing => '센서 준비 중…',
                        EnrollmentCaptureState.ready => '준비됨 · 패턴을 그려 주세요',
                        EnrollmentCaptureState.recording => '기록 중 · 손을 떼면 끝납니다',
                        EnrollmentCaptureState.finishing => '기록 마무리 중…',
                        EnrollmentCaptureState.idle => '대기 중',
                      },
                textAlign: TextAlign.center,
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold, color: _violet),
              ),
              if (!controller.isBusy && !checking && feedback != null)
                TextButton(
                    onPressed: _captureAttempt, child: const Text('다시 준비')),
            ],
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
          ],
        ),
      ),
    );
  }
}

class AuthResultScreen extends StatelessWidget {
  final bool success;
  final String displayName;

  /// 1 = pattern only, 2 = pattern + behavior (v3.2 prototype).
  final int stage;

  /// The behavioral factor was required but no model was ready.
  final bool held;
  final String? diagnostics;

  /// Training-data collection result shown to the user (stored N/40, or the
  /// automatic model training at 40).
  final String? dataNote;
  const AuthResultScreen({
    super.key,
    required this.success,
    required this.displayName,
    this.stage = 1,
    this.held = false,
    this.diagnostics,
    this.dataNote,
  });

  @override
  Widget build(BuildContext context) {
    final title = held
        ? '인증 보류'
        : !success
            ? '인증 실패'
            : stage == 2
                ? '인증되었습니다, $displayName님'
                : '패턴 인증 성공';
    final body = held
        ? '행동 인증 모델이 준비되지 않아 인증을 진행할 수 없습니다. '
            '프로필에서 모델 학습을 마친 뒤 다시 시도해 주세요.'
        : !success
            ? (stage == 2
                ? '인증에 실패했습니다. 다시 시도해 주세요.'
                : '패턴이 일치하지 않습니다. 다시 시도해 주세요.')
            : stage == 2
                ? '패턴 확인과 행동 인증을 모두 통과했습니다.'
                : '$displayName님이 그린 패턴이 등록 패턴과 일치합니다.';
    final note = held
        ? '유효 데이터가 $validDataTarget개 이상인 사용자는 행동 인증이 필요하며, '
            '모델이 없다고 패턴만으로 승인하지 않습니다.'
        : stage == 2
            ? '행동 인증은 프로토타입입니다. 임계값은 연구용 4명 데이터로 정한 임시값이며 '
                '검증된 보안 수준이 아닙니다.${success ? '' : ' 실패 횟수 제한과 잠금은 아직 동작하지 않습니다.'}'
            : success
                ? '유효 데이터가 $validDataTarget개 미만이라 1차 패턴 확인만 거쳤습니다. '
                    '$validDataTarget개가 되면 모델이 자동으로 학습되고, 그다음 로그인부터 '
                    '행동 인증(2단계)이 적용됩니다.'
                : '실패 횟수 제한과 잠금은 아직 동작하지 않습니다(준비 중).';
    return Scaffold(
      appBar: AppBar(title: const Text('인증 결과')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const SizedBox(height: 48),
            Icon(
              success ? Icons.check_circle_outline : Icons.error_outline,
              size: 80,
              color: success ? Colors.green : Colors.redAccent,
            ),
            const SizedBox(height: 20),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 24, fontWeight: FontWeight.bold, color: _ink),
            ),
            const SizedBox(height: 12),
            Text(body, textAlign: TextAlign.center),
            const SizedBox(height: 20),
            Card(
              color: const Color(0xfff3f0ff),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Text(note),
              ),
            ),
            if (dataNote != null) ...[
              const SizedBox(height: 12),
              Card(
                color: const Color(0xffeef8f0),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Text(dataNote!),
                ),
              ),
            ],
            if (success && stage == 1) ...[
              const SizedBox(height: 16),
              const OutlinedButton(
                onPressed: null,
                child: Text('2차 행동 인증 · 유효 데이터 $validDataTarget개부터 적용'),
              ),
            ],
            if (diagnostics != null)
              // Users are not told which step failed; this is for research.
              ExpansionTile(
                title: const Text('연구용 진단',
                    style: TextStyle(fontSize: 14, color: Colors.black54)),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Text(diagnostics!,
                        style: const TextStyle(fontSize: 13)),
                  ),
                ],
              ),
            const SizedBox(height: 28),
            FilledButton(
              onPressed: () => success
                  ? Navigator.popUntil(context, (route) => route.isFirst)
                  : Navigator.pop(context),
              child: Text(success ? '처음으로' : '다시 시도'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Entry list for later-stage screens. Every item is a shell only.
class PlannedFeaturesScreen extends StatelessWidget {
  const PlannedFeaturesScreen({super.key});

  static const features = [
    (
      '모델 자동 재학습',
      '데이터가 쌓일 때마다 모델을 자동으로 다시 학습하는 기능입니다. '
          '현재는 유효 데이터가 40개가 될 때 한 번만 자동으로 학습하고, '
          '이후 재학습은 프로필에서 직접 합니다.',
    ),
    (
      '잠금 대기 · 관리자 잠금',
      '인증 실패가 누적되면 30초·1분·3분·5분 대기 후 관리자 잠금으로 이어지는 화면입니다. '
          '현재 실패 횟수 제한과 잠금은 동작하지 않습니다.',
    ),
  ];

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('향후 기능')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(4, 4, 4, 12),
                child: Text('아래 기능은 화면 자리만 준비된 상태입니다. '
                    '실제 동작은 추후 구현됩니다.'),
              ),
              for (final (title, description) in features)
                Card(
                  child: ListTile(
                    title: Text(title),
                    subtitle: const Text('준비 중'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.push<void>(
                      context,
                      MaterialPageRoute(
                        builder: (_) => PlannedFeatureScreen(
                          title: title,
                          description: description,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
}

class PlannedFeatureScreen extends StatelessWidget {
  final String title, description;
  const PlannedFeatureScreen({
    super.key,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const SizedBox(height: 40),
              const Icon(Icons.construction_outlined, size: 64, color: _violet),
              const SizedBox(height: 18),
              const Text(
                '준비 중 · 추후 구현',
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 22, fontWeight: FontWeight.bold, color: _ink),
              ),
              const SizedBox(height: 14),
              Text(description, textAlign: TextAlign.center),
              const SizedBox(height: 14),
              const Text(
                '이 화면에는 실제 값이 표시되지 않습니다.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.black54),
              ),
            ],
          ),
        ),
      );
}
