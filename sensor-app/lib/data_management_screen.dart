import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import 'data_management.dart';
import 'storage.dart';
import 'share_origin.dart';
import 'export_workflow.dart';
import 'upload_queue_store.dart';
import 'drive_upload_service.dart';
import 'pattern_group_screen.dart';

const _purple = Color(0xff6847e8);
String statusName(TrialStatus s) => switch (s) {
  TrialStatus.success => '성공',
  TrialStatus.failed => '실패',
  TrialStatus.review => '검토 필요',
};

List<List<TrialSummary>> planDriveUploadBatches(
    Iterable<TrialSummary> selected) {
  final groups = <(String, String), List<TrialSummary>>{};
  for (final summary in selected) {
    groups
        .putIfAbsent((summary.participantId, summary.targetPattern), () => [])
        .add(summary);
  }
  return groups.values.toList();
}

class DataManagementScreen extends StatefulWidget {
  final SessionStorage storage;
  final ExportWorkflow workflow;
  const DataManagementScreen({
    super.key,
    required this.storage,
    required this.workflow,
  });
  @override
  State<DataManagementScreen> createState() => _DataManagementScreenState();
}

class _DataManagementScreenState extends State<DataManagementScreen> {
  List<TrialSummary>? summaries;
  Object? loadError;
  TrialStatus? filter;
  String search = '';
  final patterns = <String>{};
  final trials = <String>{};
  bool exporting = false, cancelExport = false;
  bool uploading = false;
  ExportJob? lastJob;
  String? uploadStatus;
  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    setState(() {
      summaries = null;
      loadError = null;
    });
    try {
      final data = await widget.storage.loadSummaries();
      final jobs = await widget.workflow.queue.load();
      jobs.sort((a, b) => b.createdAtUtc.compareTo(a.createdAtUtc));
      if (mounted) {
        setState(() {
          summaries = data;
          if (jobs.isNotEmpty) {
            lastJob = jobs.first;
            uploadStatus = jobs.first.state == 'uploaded'
                ? '최근 업로드 완료 · Drive ID ${jobs.first.driveFileId}'
                : '보관된 ZIP: ${jobs.first.filename} · ${jobs.first.state}';
          }
        });
      }
    } catch (e) {
      if (mounted) setState(() => loadError = e);
    }
  }

  void _message(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Set<String> get chosen => selectedIds(summaries ?? [], patterns, trials);
  Future<void> _export(
    Set<String> ids, {
    required bool diagnostics,
    bool legacy = false,
    bool drive = false,
    bool splitByPattern = false,
  }) async {
    final all = {for (final s in summaries ?? <TrialSummary>[]) s.id: s};
    final selected = ids
        .map((id) => all[id])
        .whereType<TrialSummary>()
        .toList();
    final success = selected
        .where((s) => s.status == TrialStatus.success)
        .toList();
    final failed = selected
        .where((s) => s.status == TrialStatus.failed)
        .toList();
    final review = selected
        .where((s) => s.status == TrialStatus.review)
        .toList();
    final fixedSuccess = success.where((s) => s.fixedWindowSuccess).toList();
    final legacySuccess = success.where((s) => s.legacySuccess).toList();
    final actual = diagnostics
        ? [...failed, ...review]
        : legacy
        ? legacySuccess
        : fixedSuccess;
    if (actual.isEmpty) {
      _message('내보낼 대상이 없습니다.');
      return;
    }
    final byPattern = groupTrials(actual);
    final driveBatches = planDriveUploadBatches(actual);
    if (drive &&
        byPattern.keys.any(
          (p) => !RegExp(r'^[1-9](?:-[1-9]){2,8}$').hasMatch(p),
        )) {
      _message('목표 패턴 경로가 없는 기록은 Drive 패턴 폴더로 업로드할 수 없습니다.');
      return;
    }
    var split = splitByPattern;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          title: Text(
            drive
                ? 'Google Drive로 업로드'
                : diagnostics
                ? '진단 데이터 내보내기'
                : legacy
                ? '구버전 데이터 별도 내보내기'
                : '고정창 성공 데이터 내보내기',
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '포함 패턴 ${actual.map((s) => s.targetPattern).toSet().length}개 · 대상 ${actual.length}건',
              ),
              if (drive)
                Text(
                  '참가자와 패턴별로 ${driveBatches.length}개 ZIP을 만들어 팀 폴더 아래 ${byPattern.length}개 패턴 폴더에 업로드합니다.',
                ),
              if (!drive && !diagnostics)
                Text(
                  '대상 ${actual.length}건 / 구버전 성공 ${legacy ? fixedSuccess.length : legacySuccess.length}건, 실패 ${failed.length}건, 검토 ${review.length}건 제외',
                ),
              if (legacy)
                const Text('구버전 4초 고정창 또는 DOWN~UP 절단 데이터입니다. 새 5초 학습 데이터와 합치지 마세요.'),
              if (diagnostics) const Text('학습 CSV와 분리된 진단 ZIP을 만듭니다.'),
              if (!diagnostics)
                SwitchListTile(
                  value: split,
                  title: const Text('패턴별 분할 ZIP'),
                  onChanged: (v) => update(() => split = v),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(drive ? 'Drive로 업로드' : '내보내기'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      exporting = true;
      cancelExport = false;
    });
    try {
      final batches = drive ? driveBatches : [actual];
      var completed = 0;
      for (final batch in batches) {
        final batchSelection = selected
            .where((s) =>
                s.targetPattern == batch.first.targetPattern &&
                s.participantId == batch.first.participantId)
            .toList();
        final job = await widget.workflow.prepare(
          batch.map((s) => s.id).toSet(),
          diagnostics: diagnostics,
          legacy: legacy,
          splitByPattern: drive ? false : split,
          excludedFailed: diagnostics
              ? 0
              : (drive ? batchSelection : failed)
                    .where((s) => s.status == TrialStatus.failed)
                    .length,
          excludedReview: diagnostics
              ? 0
              : (drive ? batchSelection : review)
                    .where((s) => s.status == TrialStatus.review)
                    .length,
          cancelled: () => cancelExport,
        );
        if (cancelExport) return;
        lastJob = job;
        if (!mounted) return;
        if (drive) {
          setState(() {
            uploading = true;
            uploadStatus =
                'Google Drive 업로드 중 · ${completed + 1}/${batches.length}';
          });
          final uploaded = await widget.workflow.upload(job);
          lastJob = uploaded;
          completed++;
          if (mounted) {
            setState(
              () => uploadStatus =
                  '업로드 완료 $completed/${batches.length} · Drive ID ${uploaded.driveFileId}',
            );
          }
        } else {
          final result = await SharePlus.instance.share(
            ShareParams(
              files: [XFile(job.localZipPath)],
              text: diagnostics ? '패턴 진단 데이터' : '패턴 학습 데이터',
              sharePositionOrigin: shareSheetOrigin(context),
            ),
          );
          if (result.status == ShareResultStatus.success) {
            _message('공유가 완료되었습니다.');
          }
        }
      }
    } on ExportCancelled {
      _message('내보내기를 취소했습니다.');
    } catch (e) {
      if (drive && lastJob != null) {
        if (mounted) {
          setState(
            () =>
                uploadStatus = '업로드 실패 · ZIP은 기기에 보관됨: ${driveErrorMessage(e)}',
          );
        }
      } else {
        _message('내보내기 실패: $e');
      }
    } finally {
      if (mounted) {
        setState(() {
          exporting = false;
          uploading = false;
        });
      }
    }
  }

  Future<void> _retryUpload() async {
    final job = lastJob;
    if (job == null || exporting) return;
    setState(() {
      exporting = true;
      uploading = true;
      uploadStatus = '재시도 중';
    });
    try {
      lastJob = await widget.workflow.upload(job);
      if (mounted) {
        setState(
          () => uploadStatus = '업로드 완료 · Drive ID ${lastJob!.driveFileId}',
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => uploadStatus = '재시도 실패: ${driveErrorMessage(e)}');
      }
    } finally {
      if (mounted) {
        setState(() {
          exporting = false;
          uploading = false;
        });
      }
    }
  }

  Future<void> _shareLastZip() async {
    final job = lastJob;
    if (job == null) return;
    await SharePlus.instance.share(
      ShareParams(
        files: [XFile(job.localZipPath)],
        text: '패턴 센서 데이터',
        sharePositionOrigin: shareSheetOrigin(context),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final all = summaries ?? <TrialSummary>[];
    final groups = groupTrials(
      all.where(
        (s) =>
            (filter == null || s.status == filter) &&
            (s.targetPattern.contains(search) ||
                s.displayName.contains(search)),
      ),
    );
    final visibleGroups = groups.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final selected = chosen;
    final selectedRecords = all.where((s) => selected.contains(s.id)).toList();
    final selectedFixed = selectedRecords
        .where((s) => s.fixedWindowSuccess)
        .toList();
    final selectedLegacy = selectedRecords
        .where((s) => s.legacySuccess)
        .toList();
    final selectedDiagnostic = selectedRecords
        .where(
          (s) =>
              s.status == TrialStatus.failed || s.status == TrialStatus.review,
        )
        .toList();
    final allFixed = all.where((s) => s.fixedWindowSuccess).toList();
    Set<String> ids(Iterable<TrialSummary> items) =>
        items.map((s) => s.id).toSet();

    Widget action(String label, IconData icon, VoidCallback? onTap) => ListTile(
      leading: Icon(icon, color: _purple),
      title: Text(label),
      trailing: const Icon(Icons.chevron_right),
      enabled: onTap != null,
      onTap: onTap,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('데이터 관리'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '새로고침',
            onPressed: exporting ? null : _refresh,
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: exporting
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 18),
                    Text(uploading ? 'Google Drive에 업로드 중…' : 'ZIP을 만들고 있습니다…'),
                    TextButton(
                      onPressed: uploading
                          ? null
                          : () => setState(() => cancelExport = true),
                      child: const Text('취소'),
                    ),
                  ],
                ),
              )
            : loadError != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('기록을 읽지 못했습니다: $loadError'),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: _refresh,
                        child: const Text('다시 시도'),
                      ),
                    ],
                  ),
                ),
              )
            : summaries == null
            ? const Center(child: CircularProgressIndicator())
            : CustomScrollView(
                key: const Key('data_management_scroll'),
                slivers: [
                  SliverToBoxAdapter(
                    child: Card(
                      margin: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              '수집된 기록',
                              style: TextStyle(fontWeight: FontWeight.w600),
                            ),
                            Text(
                              '${all.length}건',
                              style: const TextStyle(
                                fontSize: 26,
                                fontWeight: FontWeight.bold,
                                color: _purple,
                              ),
                            ),
                            Text(
                              '성공 ${all.where((s) => s.status == TrialStatus.success).length} · '
                              '실패 ${all.where((s) => s.status == TrialStatus.failed).length} · '
                              '검토 ${all.where((s) => s.status == TrialStatus.review).length}',
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Row(
                        children: [
                          for (final value in <TrialStatus?>[
                            null,
                            ...TrialStatus.values,
                          ])
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: ChoiceChip(
                                label: Text(
                                  value == null ? '전체' : statusName(value),
                                ),
                                selected: filter == value,
                                onSelected: (_) =>
                                    setState(() => filter = value),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                      child: TextField(
                        decoration: const InputDecoration(
                          prefixIcon: Icon(Icons.search),
                          labelText: '패턴 검색',
                          hintText: '이름 또는 점 순서',
                          border: OutlineInputBorder(),
                        ),
                        onChanged: (value) => setState(() => search = value),
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                      child: Wrap(
                        spacing: 8,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          TextButton(
                            onPressed: visibleGroups.isEmpty
                                ? null
                                : () => setState(
                                    () => patterns.addAll(
                                      visibleGroups.map((e) => e.key),
                                    ),
                                  ),
                            child: const Text('보이는 패턴 선택'),
                          ),
                          TextButton(
                            onPressed: selected.isEmpty
                                ? null
                                : () => setState(() {
                                    patterns.clear();
                                    trials.clear();
                                  }),
                            child: const Text('선택 해제'),
                          ),
                          Text(
                            '선택 ${selected.length}건',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Card(
                      color: const Color(0xfff1ebff),
                      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            const Text(
                              '선택한 성공 데이터 업로드',
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.bold,
                                color: _purple,
                              ),
                            ),
                            const SizedBox(height: 4),
                            const Text('Google Drive · 목표 패턴별 폴더와 ZIP'),
                            const SizedBox(height: 10),
                            FilledButton.icon(
                              key: const Key('data_management_primary_upload'),
                              onPressed: selectedFixed.isEmpty
                                  ? null
                                  : () => _export(
                                      ids(selectedFixed),
                                      diagnostics: false,
                                      drive: true,
                                    ),
                              icon: const Icon(Icons.cloud_upload_outlined),
                              label: Text('선택 ${selectedFixed.length}건 업로드'),
                            ),
                            if (selectedFixed.isEmpty)
                              const Text(
                                '패턴을 선택하면 고정창 성공 기록을 업로드할 수 있습니다.',
                                style: TextStyle(fontSize: 12),
                              ),
                            if (selectedLegacy.isNotEmpty ||
                                selectedDiagnostic.isNotEmpty)
                              Text(
                                '구버전 ${selectedLegacy.length}건 · 실패/검토 ${selectedDiagnostic.length}건은 기타 내보내기에서 분리합니다.',
                                style: const TextStyle(fontSize: 12),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                      child: Row(
                        children: [
                          const Icon(Icons.folder_open, color: _purple),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text(
                              '패턴별 기록',
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          Text('${visibleGroups.length}개'),
                        ],
                      ),
                    ),
                  ),
                  if (visibleGroups.isEmpty)
                    const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.all(20),
                        child: Text('표시할 패턴 기록이 없습니다.'),
                      ),
                    )
                  else
                    SliverList.builder(
                      itemCount: visibleGroups.length,
                      itemBuilder: (context, index) {
                        final group = visibleGroups[index];
                        final items = group.value;
                        return Card(
                          key: Key('data_management_group_${group.key}'),
                          margin: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 3,
                          ),
                          child: Row(
                            children: [
                              Checkbox(
                                value: patterns.contains(group.key),
                                semanticLabel: '패턴 ${group.key} 선택',
                                onChanged: (value) => setState(() {
                                  if (value == true) {
                                    patterns.add(group.key);
                                  } else {
                                    patterns.remove(group.key);
                                  }
                                }),
                              ),
                              Expanded(
                                child: ListTile(
                                  contentPadding: const EdgeInsets.only(
                                    right: 12,
                                  ),
                                  title: Text('패턴 ${group.key}'),
                                  subtitle: Text(
                                    '성공 ${items.where((s) => s.status == TrialStatus.success).length} · '
                                    '실패 ${items.where((s) => s.status == TrialStatus.failed).length} · '
                                    '검토 ${items.where((s) => s.status == TrialStatus.review).length}',
                                  ),
                                  trailing: const Icon(Icons.chevron_right),
                                  onTap: () => Navigator.push(
                                    context,
                                    MaterialPageRoute<void>(
                                      builder: (_) => PatternGroupScreen(
                                        pattern: group.key,
                                        storage: widget.storage,
                                        all: all,
                                        selected: trials,
                                        onSelectionChanged: () =>
                                            setState(() {}),
                                        onExport: (ids, diagnostics, legacy) =>
                                            _export(
                                              ids,
                                              diagnostics: diagnostics,
                                              legacy: legacy,
                                            ),
                                        onUpload: (ids, diagnostics) => _export(
                                          ids,
                                          diagnostics: diagnostics,
                                          drive: true,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  if (uploadStatus != null || lastJob != null)
                    SliverToBoxAdapter(
                      child: Card(
                        margin: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '최근 내보내기',
                                style: TextStyle(fontWeight: FontWeight.bold),
                              ),
                              if (uploadStatus != null) Text(uploadStatus!),
                              if (lastJob?.webViewLink != null)
                                SelectableText(
                                  'Drive 링크: ${lastJob!.webViewLink}',
                                ),
                              Wrap(
                                spacing: 8,
                                children: [
                                  if (lastJob != null &&
                                      lastJob!.state != 'uploaded' &&
                                      lastJob!.state != 'local_ready' &&
                                      !(lastJob!.usePatternFolder &&
                                          lastJob!.patternKey == null))
                                    OutlinedButton.icon(
                                      onPressed: _retryUpload,
                                      icon: const Icon(Icons.refresh),
                                      label: const Text('같은 ZIP 재시도'),
                                    ),
                                  if (lastJob != null)
                                    TextButton.icon(
                                      onPressed: _shareLastZip,
                                      icon: const Icon(Icons.share_outlined),
                                      label: const Text('기기에 저장/공유'),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  SliverToBoxAdapter(
                    child: Card(
                      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                      child: ExpansionTile(
                        key: const Key('data_management_more_exports'),
                        title: const Text(
                          '기타 내보내기',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: const Text('로컬 저장·진단·구버전·전체 기록'),
                        children: [
                          action(
                            '선택 고정창 성공 내보내기 (${selectedFixed.length})',
                            Icons.file_download_outlined,
                            selectedFixed.isEmpty
                                ? null
                                : () => _export(
                                    ids(selectedFixed),
                                    diagnostics: false,
                                  ),
                          ),
                          action(
                            '선택 구버전 별도 내보내기 (${selectedLegacy.length})',
                            Icons.history_outlined,
                            selectedLegacy.isEmpty
                                ? null
                                : () => _export(
                                    ids(selectedLegacy),
                                    diagnostics: false,
                                    legacy: true,
                                  ),
                          ),
                          action(
                            '선택 실패/검토 내보내기 (${selectedDiagnostic.length})',
                            Icons.description_outlined,
                            selectedDiagnostic.isEmpty
                                ? null
                                : () => _export(
                                    ids(selectedDiagnostic),
                                    diagnostics: true,
                                  ),
                          ),
                          action(
                            '선택 실패/검토 Drive 업로드 (${selectedDiagnostic.length})',
                            Icons.cloud_upload_outlined,
                            selectedDiagnostic.isEmpty
                                ? null
                                : () => _export(
                                    ids(selectedDiagnostic),
                                    diagnostics: true,
                                    drive: true,
                                  ),
                          ),
                          const Divider(height: 1),
                          action(
                            '전체 고정창 성공 내보내기 (${allFixed.length})',
                            Icons.file_download_outlined,
                            allFixed.isEmpty
                                ? null
                                : () => _export(
                                    ids(allFixed),
                                    diagnostics: false,
                                  ),
                          ),
                          action(
                            '전체 성공 Drive 업로드 · 패턴별 ZIP',
                            Icons.cloud_upload_outlined,
                            allFixed.isEmpty
                                ? null
                                : () => _export(
                                    ids(allFixed),
                                    diagnostics: false,
                                    drive: true,
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  SliverPadding(
                    padding: EdgeInsets.only(
                      bottom: 32 + MediaQuery.viewInsetsOf(context).bottom,
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}
