import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'capture.dart';
import 'model.dart';
import 'pattern_catalog.dart';
import 'storage.dart';
import 'data_management.dart';
import 'data_management_screen.dart';
import 'share_origin.dart';
import 'export_workflow.dart';
import 'google_auth_service.dart';
import 'drive_upload_service.dart';
import 'upload_queue_store.dart';
import 'enrollment_screen.dart';
import 'pattern_board.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  runApp(const CollectorApp());
}

const violet = Color(0xff6847e8);
const ink = Color(0xff201957);
const pale = Color(0xfff3f0ff);
double? nativeSeconds(Object? value) => value is num ? value.toDouble() : null;

class CollectorApp extends StatelessWidget {
  final bool legacyCollector;
  const CollectorApp({super.key, this.legacyCollector = false});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'MotionPrint',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          scaffoldBackgroundColor: const Color(0xfffaf9ff),
          colorScheme: ColorScheme.fromSeed(seedColor: violet, primary: violet),
          appBarTheme: const AppBarTheme(
            backgroundColor: Color(0xfffaf9ff),
            foregroundColor: ink,
          ),
          filledButtonTheme: FilledButtonThemeData(
            style: FilledButton.styleFrom(
              backgroundColor: violet,
              minimumSize: const Size(double.infinity, 52),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ),
        home: legacyCollector ? const CollectorHome() : const EnrollmentHome(),
      );
}

enum Screen { settings, patterns, collect, result }

enum CaptureState { idle, starting, armed, recording, saving }

class CollectorHome extends StatefulWidget {
  const CollectorHome({super.key});
  @override
  State<CollectorHome> createState() => _CollectorHomeState();
}

class _CollectorHomeState extends State<CollectorHome>
    with WidgetsBindingObserver {
  SessionStorage? storage;
  ExportWorkflow? workflow;
  final googleAuth = GoogleAuthService.instance;
  ExportJob? resultJob;
  String? uploadState;
  String? folderStatus;
  final api = CaptureApi();
  StreamSubscription<Map<String, dynamic>>? touchSubscription;
  Timer? armTimer;
  Timer? clockTimer, deadlineTimer;
  Stopwatch? buttonWatch;
  double elapsedSeconds = 0, clockOffsetSeconds = 0;
  double? buttonT0, captureStart, captureEnd;
  double buttonDispatchDelayMs = 0;
  final pendingTouches = <Map<String, dynamic>>[];
  final participant = TextEditingController();
  final device = TextEditingController();
  String hand = 'unknown', posture = 'unknown', holdingHand = 'unknown';
  int goal = 10, selected = 0, success = 0, attempt = 0;
  String sessionId = '';
  Screen screen = Screen.settings;
  CaptureState capture = CaptureState.idle;
  PatternTracker? tracker;
  TrialRecord? last;
  TrialQuality? quality;
  bool saved = false;
  bool sharing = false;
  String? error;
  List<Map<String, dynamic>> patterns = PatternCatalog.defaults();
  int bundledPatternCount = PatternCatalog.bundledCount;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    googleAuth.addListener(_authChanged);
    googleAuth.initialize();
    _load();
  }

  void _authChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    armTimer?.cancel();
    clockTimer?.cancel();
    deadlineTimer?.cancel();
    touchSubscription?.cancel();
    googleAuth.removeListener(_authChanged);
    workflow?.dispose();
    participant.dispose();
    device.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed &&
        (capture == CaptureState.armed ||
            capture == CaptureState.recording ||
            capture == CaptureState.starting)) {
      tracker?.error = 'app_backgrounded';
      _complete(force: true);
    }
  }

  String _id(String prefix) =>
      '$prefix${DateTime.now().microsecondsSinceEpoch}_${Random.secure().nextInt(0xffffff).toRadixString(16)}';
  List<int> get target =>
      PatternRules.normalize((patterns[selected]['nodes'] as List).cast<int>());
  Future<void> _load() async {
    final dir = await getApplicationDocumentsDirectory();
    storage = SessionStorage(Directory('${dir.path}/pattern_sensor_collector'));
    await storage!.ensureDeviceIdentity();
    workflow = ExportWorkflow.production(storage!);
    final config = await storage!.loadSettings();
    participant.text = config['participant'] ?? _id('P');
    device.text = config['device'] ?? _id('phone');
    hand = config['hand'] ?? 'unknown';
    posture = config['posture'] ?? 'unknown';
    holdingHand = config['holdingHand'] ?? 'unknown';
    goal = config['goal'] ?? 10;
    final catalog = PatternCatalog.resolve(config['patterns']);
    patterns = catalog.patterns;
    bundledPatternCount = catalog.bundledCount;
    goal = PatternCatalog.recommendedGoal(patterns[selected]) ?? goal;
    if (catalog.migrated) {
      await storage!.saveSettings({...config, 'patterns': patterns});
    }
    sessionId = _id('S');
    // Existing JSON records are indexed without changing or deleting the source.
    await storage!.loadSummaries();
    if (mounted) setState(() {});
  }

  Future<void> _saveConfig() async {
    final current = storage;
    if (current == null) return;
    await current.saveSettings({
      ...await current.loadSettings(),
      'participant': participant.text.trim(),
      'device': device.text.trim(),
      'hand': hand,
      'posture': posture,
      'holdingHand': holdingHand,
      'goal': goal,
      'patterns': patterns,
    });
  }

  void _message(String text) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> _start() async {
    if (capture != CaptureState.idle) return;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (!mounted ||
        (lifecycle != null && lifecycle != AppLifecycleState.resumed)) {
      return;
    }
    buttonWatch = Stopwatch()..start();
    clockOffsetSeconds = 0;
    buttonT0 = null;
    captureStart = null;
    captureEnd = null;
    buttonDispatchDelayMs = 0;
    pendingTouches.clear();
    clockTimer?.cancel();
    deadlineTimer?.cancel();
    setState(() {
      capture = CaptureState.starting;
      elapsedSeconds = 0;
      tracker = PatternTracker();
      error = null;
      last = null;
      resultJob = null;
      uploadState = null;
      quality = null;
      saved = false;
    });
    clockTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted ||
          capture == CaptureState.idle ||
          capture == CaptureState.saving) {
        return;
      }
      final measured =
          buttonWatch!.elapsedMicroseconds / 1e6 + clockOffsetSeconds;
      setState(() => elapsedSeconds = min(5.0, max(elapsedSeconds, measured)));
    });
    try {
      await touchSubscription?.cancel();
      if (!mounted || capture != CaptureState.starting) return;
      touchSubscription = api.touches.listen(
        _onTouch,
        onError: (Object e) {
          tracker?.error = 'touch_channel_error';
          _complete(force: true);
        },
      );
      final started = await api.startFixed().timeout(
            const Duration(seconds: 5),
          );
      if (!mounted || capture != CaptureState.starting) return;
      buttonT0 = (started['buttonT0'] as num).toDouble();
      captureStart = (started['captureStart'] as num).toDouble();
      captureEnd = (started['captureEnd'] as num).toDouble();
      final nativeElapsed =
          (started['nativeNow'] as num).toDouble() - buttonT0!;
      final watchElapsed = buttonWatch!.elapsedMicroseconds / 1e6;
      buttonDispatchDelayMs = max(0, (watchElapsed - nativeElapsed) * 1000);
      clockOffsetSeconds = max(0, nativeElapsed - watchElapsed);
      setState(() => capture = CaptureState.armed);
      final queued = List<Map<String, dynamic>>.of(pendingTouches);
      pendingTouches.clear();
      for (final event in queued) {
        _onTouch(event);
      }
      final remaining = max(
        0,
        captureEnd! - (started['nativeNow'] as num).toDouble(),
      );
      deadlineTimer = Timer(
        Duration(microseconds: (remaining * 1e6).ceil()),
        () {
          if (capture != CaptureState.idle && capture != CaptureState.saving) {
            _complete();
          }
        },
      );
    } catch (e) {
      if (capture != CaptureState.starting) return;
      tracker?.error = 'CAPTURE_ERROR';
      error = '센서 시작 오류: $e';
      await _complete(force: true);
    }
  }

  void _onTouch(Map<String, dynamic> event) {
    if (capture == CaptureState.starting) {
      pendingTouches.add(event);
      return;
    }
    if (capture != CaptureState.armed && capture != CaptureState.recording) {
      return;
    }
    tracker!.accept(event,
        captureStart: captureStart == null ? null : captureStart! + 0.5,
        captureEnd: captureEnd);
    if (event['type'] == 'DOWN') {
      setState(() => capture = CaptureState.recording);
    } else {
      setState(() {});
    }
  }

  Future<void> _complete({bool force = false}) async {
    if (capture == CaptureState.saving || capture == CaptureState.idle) return;
    armTimer?.cancel();
    deadlineTimer?.cancel();
    clockTimer?.cancel();
    buttonWatch?.stop();
    if (!force) elapsedSeconds = 5.0;
    setState(() => capture = CaptureState.saving);
    try {
      final native = await api.finishFixed(force: force);
      await touchSubscription?.cancel();
      final t = tracker ?? PatternTracker();
      final raw = (native['sensors'] as List? ?? [])
          .map((e) => SensorSample.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      final start = t.start ?? nativeSeconds(native['start']) ?? 0;
      final end = t.end ?? nativeSeconds(native['end']) ?? start;
      final t0 = buttonT0 ?? nativeSeconds(native['buttonT0']);
      final fixedStart = captureStart ?? nativeSeconds(native['captureStart']);
      final fixedEnd = captureEnd ?? nativeSeconds(native['captureEnd']);
      final touchError = t.error ??
          (force
              ? 'INTERRUPTED'
              : t.start == null
                  ? 'NO_INPUT_IN_WINDOW'
                  : t.end == null
                      ? 'WINDOW_TIMEOUT'
                      : null);
      attempt++;
      final record = TrialRecord(
        id: _id('T'),
        sessionId: sessionId,
        index: attempt,
        participantId: participant.text.trim(),
        deviceId: device.text.trim(),
        hand: hand,
        posture: posture,
        holdingHand: holdingHand,
        target: target,
        visits: List.of(t.visits),
        touches: List.of(t.touches),
        sensors: raw,
        start: start,
        end: end,
        clockErrorMs: (native['clockErrorMs'] as num?)?.toDouble() ?? 0,
        platform: Platform.operatingSystem,
        model: native['model']?.toString() ?? '',
        osVersion: native['osVersion']?.toString() ?? '',
        targetDisplayName: patterns[selected]['name']?.toString() ?? '',
        captureError: touchError,
        captureMode: TrialRecord.fixedWindow5Mode,
        hitRadiusNorm: PatternTracker.hitRadius,
        buttonT0Monotonic: t0,
        captureStartMonotonic: fixedStart,
        captureEndMonotonic: fixedEnd,
        actualTouchDown: t.start,
        actualTouchUp: t.end,
        windowComplete: native['windowComplete'] == true && !force,
        windowError: native['windowError'] is String
            ? native['windowError'] as String
            : null,
        buttonDispatchDelayMs: buttonDispatchDelayMs,
        deadlineErrorMs: (native['deadlineErrorMs'] as num?)?.toDouble() ?? 0,
      );
      final q = assess(record);
      // Source record is flushed before any success is counted or shown.
      await storage!.saveTrial(record);
      if (TrialSummary.fromRecord(record).status == TrialStatus.success) {
        success++;
      }
      if (mounted) {
        setState(() {
          last = record;
          quality = q;
          saved = true;
          capture = CaptureState.idle;
          screen = Screen.result;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          capture = CaptureState.idle;
          saved = false;
          error = '저장 실패: $e';
          screen = Screen.result;
        });
      }
    }
  }

  Future<void> _share() async {
    final id = last?.id;
    if (id == null || !saved || sharing || capture != CaptureState.idle) return;
    final status = TrialSummary.fromRecord(last!).status;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('이번 입력 1건 내보내기'),
        content: Text('이번 입력 1건 ($id / ${statusName(status)})을 내보냅니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('내보내기'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => sharing = true);
    try {
      final job = await workflow!.prepare({
        id,
      }, diagnostics: status != TrialStatus.success);
      resultJob = job;
      if (!mounted) return;
      final result = await SharePlus.instance.share(
        ShareParams(
          files: [XFile(job.localZipPath)],
          text: '패턴 센서 연구 데이터',
          sharePositionOrigin: shareSheetOrigin(context),
        ),
      );
      if (result.status == ShareResultStatus.success) _message('공유가 완료되었습니다.');
    } catch (e) {
      _message('ZIP 내보내기 실패: $e');
    } finally {
      if (mounted) setState(() => sharing = false);
    }
  }

  Future<void> _uploadLast() async {
    final id = last?.id;
    if (id == null || !saved || sharing || workflow == null) return;
    setState(() {
      sharing = true;
      uploadState = '로컬 ZIP 준비 중';
    });
    try {
      final status = TrialSummary.fromRecord(last!).status;
      final job =
          resultJob?.trialIds.length == 1 && resultJob!.trialIds.single == id
              ? resultJob!
              : await workflow!.prepare({
                  id,
                }, diagnostics: status != TrialStatus.success);
      resultJob = job;
      if (mounted) setState(() => uploadState = 'Google Drive 업로드 중');
      final uploaded = await workflow!.upload(job);
      resultJob = uploaded;
      if (mounted) {
        setState(
          () => uploadState = '업로드 완료 · Drive ID ${uploaded.driveFileId}',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => uploadState = '업로드 실패 · ZIP은 기기에 보관됨: ${driveErrorMessage(e)}',
        );
      }
    } finally {
      if (mounted) setState(() => sharing = false);
    }
  }

  Future<void> _connectGoogle() async {
    try {
      await googleAuth.connect();
      if (mounted) setState(() => folderStatus = null);
      _message('계정 연결됨. 팀 폴더 접근은 별도 확인하세요.');
    } catch (e) {
      _message('계정 연결 또는 추가 Drive 권한 승인 실패: ${driveErrorMessage(e)}');
    }
  }

  Future<void> _changeGoogle() async {
    try {
      await googleAuth.disconnect();
      if (mounted) setState(() => folderStatus = null);
      await googleAuth.connect();
      _message('계정을 변경했습니다. 이전 계정의 대기 ZIP은 자동 전송하지 않습니다.');
    } catch (_) {
      _message('계정 변경을 취소했거나 OAuth 설정이 올바르지 않습니다.');
    }
  }

  Future<void> _checkTeamFolder() async {
    try {
      final token = await googleAuth.authorization(interactive: true);
      final folder = await workflow!.drive.checkFolder(token.accessToken);
      if (mounted) {
        setState(() => folderStatus = '읽기 확인: ${folder['name']} · 쓰기는 업로드로 확인');
      }
      _message('팀 폴더 확인: ${folder['name']} · 쓰기 권한은 실제 업로드로 확인하세요.');
    } catch (e) {
      if (mounted) setState(() => folderStatus = driveErrorMessage(e));
      _message('팀 폴더 확인 실패: ${driveErrorMessage(e)}');
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
        canPop: capture == CaptureState.idle,
        child: Scaffold(
          appBar: AppBar(
            title: Text(switch (screen) {
              Screen.settings => '초기 설정',
              Screen.patterns => '패턴 선택 / 생성',
              Screen.collect => '패턴 입력 (${min(success + 1, goal)} / $goal)',
              Screen.result => '입력 완료 ($success / $goal)',
            }),
            leading: screen == Screen.settings
                ? null
                : IconButton(
                    icon: const Icon(Icons.arrow_back),
                    onPressed: () {
                      if (capture == CaptureState.idle) {
                        setState(
                          () => screen = screen == Screen.patterns
                              ? Screen.settings
                              : Screen.patterns,
                        );
                      }
                    },
                  ),
            actions: [
              TextButton.icon(
                onPressed:
                    capture == CaptureState.idle && !sharing && storage != null
                        ? () {
                            Navigator.push(
                              context,
                              MaterialPageRoute<void>(
                                builder: (_) => DataManagementScreen(
                                  storage: storage!,
                                  workflow: workflow!,
                                ),
                              ),
                            );
                          }
                        : null,
                icon: const Icon(Icons.folder_open),
                label: const Text('데이터 관리'),
              ),
            ],
          ),
          body: SafeArea(
            child: switch (screen) {
              Screen.settings => _settings(),
              Screen.patterns => _patterns(),
              Screen.collect => _collect(),
              Screen.result => _result(),
            },
          ),
        ),
      );

  Widget _settings() => ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const SizedBox(height: 18),
          const Text(
            'Pattern Sensor Collector',
            style: TextStyle(
                fontSize: 25, fontWeight: FontWeight.bold, color: ink),
          ),
          const SizedBox(height: 8),
          const Text('연구용 패턴 입력 중 가속도계와 자이로스코프를 수집합니다.\n실제 잠금 패턴은 입력하지 마세요.'),
          const SizedBox(height: 25),
          _card(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: participant,
                  decoration: const InputDecoration(
                    labelText: '익명 참가자 ID',
                    prefixIcon: Icon(Icons.person_outline),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: device,
                  decoration: const InputDecoration(
                    labelText: '익명 기기 라벨',
                    prefixIcon: Icon(Icons.phone_android),
                  ),
                ),
                const Text(
                  'ZIP 이름에는 설치본 고유 ID도 함께 들어갑니다.',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
                const SizedBox(height: 18),
                const Text('패턴을 그리는 손'),
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'unknown', label: Text('미선택')),
                    ButtonSegment(value: 'left', label: Text('왼손')),
                    ButtonSegment(value: 'right', label: Text('오른손')),
                  ],
                  selected: {hand},
                  onSelectionChanged: (v) => setState(() => hand = v.first),
                ),
                const SizedBox(height: 18),
                const Text('몸 자세'),
                DropdownButtonFormField<String>(
                  key: ValueKey("posture:$posture"),
                  initialValue: posture,
                  items: const [
                    DropdownMenuItem(value: 'unknown', child: Text('미선택')),
                    DropdownMenuItem(value: 'seated', child: Text('앉음')),
                    DropdownMenuItem(value: 'standing', child: Text('서 있음')),
                    DropdownMenuItem(value: 'other', child: Text('기타')),
                  ],
                  onChanged: (v) => setState(() => posture = v!),
                ),
                const SizedBox(height: 18),
                const Text('휴대폰을 잡는 손 (보조 정보)'),
                DropdownButtonFormField<String>(
                  key: ValueKey("holdingHand:$holdingHand"),
                  initialValue: holdingHand,
                  items: const [
                    DropdownMenuItem(value: 'unknown', child: Text('미선택')),
                    DropdownMenuItem(value: 'left', child: Text('왼손')),
                    DropdownMenuItem(value: 'right', child: Text('오른손')),
                    DropdownMenuItem(value: 'both', child: Text('양손')),
                  ],
                  onChanged: (v) => setState(() => holdingHand = v!),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          _card(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Google Drive 연결',
                  style: TextStyle(fontWeight: FontWeight.bold, color: ink),
                ),
                const Text('고정 팀 폴더: 1TL4q-bXzogl5LEL2uS0qj055K0nxnNAI'),
                const SelectableText(
                    'https://drive.google.com/drive/u/0/folders/1TL4q-bXzogl5LEL2uS0qj055K0nxnNAI'),
                if (folderStatus != null) Text(folderStatus!),
                Text(
                  !googleAuth.configured
                      ? 'OAuth 클라이언트 설정 필요'
                      : googleAuth.connected
                          ? '연결됨 · ${googleAuth.displayName ?? 'Google 계정'}'
                          : '미연결',
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    OutlinedButton(
                      onPressed: googleAuth.configured ? _connectGoogle : null,
                      child: const Text('Google 계정 연결'),
                    ),
                    OutlinedButton(
                      onPressed: googleAuth.connected && workflow != null
                          ? _checkTeamFolder
                          : null,
                      child: const Text('접근 확인'),
                    ),
                    TextButton(
                      onPressed: googleAuth.connected
                          ? () async {
                              await googleAuth.disconnect();
                              if (mounted) setState(() => folderStatus = null);
                              _message('연결을 해제했습니다. 로컬 ZIP은 유지됩니다.');
                            }
                          : null,
                      child: const Text('연결 해제'),
                    ),
                    TextButton(
                        onPressed: googleAuth.connected ? _changeGoogle : null,
                        child: const Text('계정 변경')),
                  ],
                ),
                const Text('폴더 접근과 파일 추가 권한은 다릅니다. 실제 업로드로 확인하세요.'),
              ],
            ),
          ),
          const SizedBox(height: 18),
          const Text('휴대폰을 손에 들고 같은 조건을 유지해 주세요.',
              style: TextStyle(color: ink)),
          if (hand == 'unknown')
            const Text(
              '그리는 손 미선택: 학습 데이터 품질에 영향을 줄 수 있습니다.',
              style: TextStyle(color: Colors.orange),
            ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: () async {
              if (participant.text.trim().isEmpty ||
                  device.text.trim().isEmpty) {
                _message('참가자 ID와 기기 라벨을 입력해 주세요.');
                return;
              }
              await _saveConfig();
              setState(() => screen = Screen.patterns);
            },
            child: const Text('다음 →'),
          ),
        ],
      );

  Widget _patterns() => ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            '연구용 패턴을 선택하세요',
            style: TextStyle(
                fontSize: 20, fontWeight: FontWeight.bold, color: ink),
          ),
          const SizedBox(height: 12),
          ...List.generate(
            patterns.length,
            (i) => Card(
              color: i == selected ? pale : Colors.white,
              child: ListTile(
                leading: const Icon(Icons.grid_3x3, color: violet),
                title: Text(patterns[i]['name']),
                subtitle: Text(
                  PatternRules.normalize(
                          (patterns[i]['nodes'] as List).cast<int>())
                      .join(' - '),
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (i >= bundledPatternCount)
                      IconButton(
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () => _editPattern(i),
                      ),
                    if (i >= bundledPatternCount)
                      IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          setState(() {
                            patterns.removeAt(i);
                            selected = 0;
                            goal = PatternCatalog.recommendedGoal(patterns[0]) ?? goal;
                          });
                          await _saveConfig();
                        },
                      ),
                    Icon(
                      i == selected
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      color: violet,
                    ),
                  ],
                ),
                onTap: () => setState(() {
                  goal = PatternCatalog.recommendedGoal(patterns[i]) ?? goal;
                  if (selected != i) {
                    selected = i;
                    success = 0;
                    attempt = 0;
                    sessionId = _id('S');
                  }
                }),
              ),
            ),
          ),
          OutlinedButton.icon(
            onPressed: () => _editPattern(null),
            icon: const Icon(Icons.add),
            label: const Text('새 패턴 만들기'),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              const Text('목표 성공 횟수',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const Spacer(),
              IconButton(
                onPressed: goal > 1 ? () => setState(() => goal--) : null,
                icon: const Icon(Icons.remove),
              ),
              Text(
                '$goal',
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              IconButton(
                onPressed: goal < 100 ? () => setState(() => goal++) : null,
                icon: const Icon(Icons.add),
              ),
            ],
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: () async {
              await _saveConfig();
              setState(() => screen = Screen.collect);
            },
            child: const Text('입력 화면으로 →'),
          ),
        ],
      );

  Future<void> _editPattern(int? index) async {
    final name = TextEditingController(
      text: index == null ? '' : patterns[index]['name'],
    );
    final points = <int>[];
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          title: Text(index == null ? '새 패턴 만들기' : '패턴 수정'),
          content: SizedBox(
            width: 300,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: '패턴 이름'),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: 240,
                  height: 240,
                  child: GestureDetector(
                    onPanStart: (d) => update(() {
                      points.clear();
                      _editorHit(d.localPosition, 240, points);
                    }),
                    onPanUpdate: (d) =>
                        update(() => _editorHit(d.localPosition, 240, points)),
                    child: CustomPaint(
                      painter: BoardPainter(
                        target: PatternRules.normalize(points),
                        actual: const [],
                      ),
                    ),
                  ),
                ),
                Text(PatternRules.normalize(points).join(' - ')),
                const Text(
                  '3~9개 점을 한 번에 그려 주세요.',
                  style: TextStyle(fontSize: 12),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('취소'),
            ),
            TextButton(
              onPressed: () async {
                final normalized = PatternRules.normalize(points);
                if (name.text.trim().isEmpty ||
                    normalized.length < 3 ||
                    normalized.length > 9) {
                  _message('이름과 3~9개 점이 필요합니다.');
                  return;
                }
                setState(() {
                  if (index == null) {
                    patterns.add({
                      'name': name.text.trim(),
                      'nodes': normalized,
                    });
                    selected = patterns.length - 1;
                  } else {
                    patterns[index] = {
                      'name': name.text.trim(),
                      'nodes': normalized,
                    };
                    selected = index;
                  }
                });
                await _saveConfig();
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('저장'),
            ),
          ],
        ),
      ),
    );
    name.dispose();
  }

  void _editorHit(Offset p, double size, List<int> points) {
    for (var n = 1; n <= 9; n++) {
      final c = nodePoint(n);
      if ((p.dx / size - c.$1).abs() < 0.12 &&
          (p.dy / size - c.$2).abs() < 0.12 &&
          !points.contains(n)) {
        points.add(n);
        break;
      }
    }
  }

  Widget _collect() => Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            _card(
              Column(
                children: [
                  Text(
                    capture == CaptureState.idle
                        ? '목표 패턴: ${target.join(' → ')}'
                        : capture == CaptureState.saving
                            ? '저장 중…'
                            : elapsedSeconds < 0.5
                                ? '잠시 대기 (0.5초)'
                                : '패턴 입력 가능 · 남은 시간 ${(5.0 - elapsedSeconds).clamp(0, 4.5).toStringAsFixed(1)}초',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, color: ink),
                  ),
                  if (capture != CaptureState.idle)
                    Text(
                      '${elapsedSeconds.toStringAsFixed(1)}초',
                      key: const Key('capture_stopwatch'),
                      style: const TextStyle(
                        fontSize: 38,
                        fontWeight: FontWeight.bold,
                        color: violet,
                      ),
                    ),
                  Text(
                    '성공 $success / $goal회 · 버튼 후 0.5초 대기, 5초 전에 입력 완료',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
            const Spacer(),
            LayoutBuilder(
              builder: (context, constraints) {
                final size = min(constraints.maxWidth, 390.0);
                return Center(
                  child: SizedBox(
                    width: size,
                    height: size,
                    child: Stack(
                      children: [
                        CustomPaint(
                          size: Size(size, size),
                          painter: BoardPainter(
                            target: target,
                            actual:
                                tracker?.visits.map((v) => v.node).toList() ??
                                    [],
                          ),
                        ),
                        if (Platform.isAndroid)
                          const AndroidView(
                              viewType: 'pattern_sensor/touch_view'),
                        if (Platform.isIOS)
                          const UiKitView(
                              viewType: 'pattern_sensor/touch_view'),
                      ],
                    ),
                  ),
                );
              },
            ),
            const Spacer(),
            if (error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(error!, style: const TextStyle(color: Colors.red)),
              ),
            FilledButton.icon(
              onPressed: capture == CaptureState.idle ? _start : null,
              icon: const Icon(Icons.play_arrow),
              label: const Text('입력 시작'),
            ),
            const SizedBox(height: 12),
            const Text(
              '가이드선은 입력 중에도 유지됩니다. 진동과 소리는 사용하지 않습니다.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      );

  Widget _result() {
    final t = last, q = quality;
    final status = t == null ? null : TrialSummary.fromRecord(t).status;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _card(
          Text(
            saved ? '✓ 앱 내부에 자동 저장됨' : '저장되지 않았습니다. 다시 시도해 주세요.',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: saved ? Colors.green : Colors.red,
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (t != null)
          _card(
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '상태: ${status == null ? '기록 없음' : statusName(status)} · trial_id: ${t.id}',
                ),
                const Text('목표 패턴'),
                Text(
                  t.target.join(' - '),
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: ink,
                  ),
                ),
                const Divider(),
                const Text('실제 입력 패턴'),
                Text(
                  t.actual.join(' - '),
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: violet,
                  ),
                ),
                const Divider(),
                Text('일치 여부: ${t.matched ? '일치' : '불일치'}'),
                Text('기록 시간: ${(t.end - t.start).toStringAsFixed(2)}초'),
                if (t.captureMode == TrialRecord.fixedWindow5Mode)
                  const Text(
                    '학습 센서 구간: 버튼 기준 0초 이상, 5초 미만 (5초) · 터치 시각은 라벨',
                  )
                else if (t.captureMode == TrialRecord.fixedWindowMode)
                  const Text(
                    '학습 센서 구간: 버튼 기준 0.5초 이상, 4.5초 미만 (4초) · 터치 시각은 라벨',
                  ),
                Text('원시 센서 이벤트: ${t.sensors.length}개'),
                Text(
                  '학습용 6축 행: ${q?.eligible == true ? q!.joined.rows.length : 0}개',
                ),
                Text(
                  status == TrialStatus.success
                      ? '학습 CSV 포함'
                      : '학습 CSV 제외: ${q?.reason.isNotEmpty == true ? q!.reason : status == TrialStatus.failed ? '목표 패턴 불일치' : '알 수 없음'}',
                ),
              ],
            ),
          ),
        if (error != null)
          Text(error!, style: const TextStyle(color: Colors.red)),
        const SizedBox(height: 20),
        Text(
          '성공 $success / $goal회 · 전체 시도 $attempt회',
          style: const TextStyle(fontWeight: FontWeight.bold, color: ink),
        ),
        const SizedBox(height: 20),
        FilledButton.icon(
          onPressed: saved && !sharing ? _uploadLast : null,
          icon: const Icon(Icons.cloud_upload_outlined),
          label: const Text('이번 입력 1건 Drive로 업로드'),
        ),
        if (uploadState != null) Text(uploadState!),
        if (resultJob?.driveFileId != null)
          Text('Drive 파일 ID: ${resultJob!.driveFileId}'),
        if (resultJob?.webViewLink != null)
          SelectableText('Drive 링크: ${resultJob!.webViewLink}'),
        OutlinedButton.icon(
          onPressed: saved && !sharing ? _share : null,
          icon: const Icon(Icons.archive_outlined),
          label: const Text('이번 입력 1건 기기에 저장/공유'),
        ),
        const Text('여러 입력을 묶으려면 데이터 관리에서 선택하세요.', textAlign: TextAlign.center),
        const SizedBox(height: 10),
        FilledButton(
          onPressed: () {
            setState(() {
              tracker = null;
              last = null;
              quality = null;
              error = null;
              screen = Screen.collect;
            });
          },
          child: Text(
            success >= goal
                ? '새 입력 계속하기'
                : '다음 입력 시작 (${min(success + 1, goal)} / $goal)',
          ),
        ),
      ],
    );
  }

  Widget _card(Widget child) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: const Color(0xffe8e4f4)),
          boxShadow: const [
            BoxShadow(color: Color(0x0c352080), blurRadius: 12)
          ],
        ),
        child: child,
      );
}
