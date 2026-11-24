import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'data_management.dart';
import 'model.dart';
import 'storage.dart';

const _purple = Color(0xff6847e8);
const _pale = Color(0xfff1ebff);

String shortTrialId(String id) => id.length <= 18
    ? id
    : '${id.substring(0, 10)}…${id.substring(id.length - 6)}';

String _statusName(TrialStatus s) => switch (s) {
      TrialStatus.success => '성공',
      TrialStatus.failed => '실패',
      TrialStatus.review => '검토 필요',
    };

String _timeLabel(DateTime value, DateTime now) {
  if (value.year < 2000) return '시각 없음';
  final local = value.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  final time = '${two(local.hour)}:${two(local.minute)}:${two(local.second)}';
  return local.year == now.year &&
          local.month == now.month &&
          local.day == now.day
      ? time
      : '${two(local.month)}/${two(local.day)} $time';
}

class PatternGroupScreen extends StatefulWidget {
  final String pattern;
  final SessionStorage storage;
  final List<TrialSummary> all;
  final Set<String> selected;
  final VoidCallback onSelectionChanged;
  final Future<void> Function(Set<String>, bool, bool) onExport;
  final Future<void> Function(Set<String>, bool) onUpload;
  const PatternGroupScreen({
    super.key,
    required this.pattern,
    required this.storage,
    required this.all,
    required this.selected,
    required this.onSelectionChanged,
    required this.onExport,
    required this.onUpload,
  });

  @override
  State<PatternGroupScreen> createState() => _PatternGroupScreenState();
}

class _PatternGroupScreenState extends State<PatternGroupScreen> {
  TrialStatus? filter;

  void _update(VoidCallback action) {
    setState(action);
    widget.onSelectionChanged();
  }

  Future<void> _showTrial(TrialSummary summary) async {
    final trialFuture = widget.storage.loadTrial(summary.id);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('기록 상세'),
        content: SizedBox(
          width: 360,
          child: FutureBuilder<TrialRecord?>(
            future: trialFuture,
            builder: (ctx, snapshot) {
              if (snapshot.hasError) {
                return Text('원본을 읽지 못했습니다: ${snapshot.error}');
              }
              if (!snapshot.hasData &&
                  snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              final trial = snapshot.data;
              final visits = trial == null
                  ? '원본 터치 시각을 확인할 수 없습니다.'
                  : trial.visits
                      .map((v) =>
                          '${v.node}번: ${v.time.toStringAsFixed(9)}초${v.estimated ? ' (추정)' : ''}')
                      .join('\n');
              return SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('전체 기록 ID',
                        style: TextStyle(fontWeight: FontWeight.bold)),
                    SelectableText(summary.id),
                    TextButton.icon(
                      onPressed: () async {
                        await Clipboard.setData(
                            ClipboardData(text: summary.id));
                        if (ctx.mounted) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            const SnackBar(content: Text('기록 ID를 복사했습니다.')),
                          );
                        }
                      },
                      icon: const Icon(Icons.copy_outlined),
                      label: const Text('ID 복사'),
                    ),
                    Text(
                      '상태: ${_statusName(summary.status)}\n수집 방식: ${summary.captureMode}\n참가자: ${summary.participantId}\n세션: ${summary.sessionId}\n'
                      '목표: ${summary.targetPattern}\n실제: ${summary.actualPattern}\n사유: ${summary.reason}\n'
                      '가속도 ${summary.accelCount} · 자이로 ${summary.gyroCount} · 학습 행 ${summary.mlRowCount}\n'
                      '기록 시각: ${summary.createdAt.toLocal()}\n\n점별 도착 시각\n$visits',
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('닫기'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final group = widget.all
        .where((s) => s.targetPattern == widget.pattern)
        .toList()
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    final shown =
        group.where((s) => filter == null || s.status == filter).toList();
    final selected =
        group.where((s) => widget.selected.contains(s.id)).toList();
    final selectedFixed = selected.where((s) => s.fixedWindowSuccess).toList();
    final selectedLegacy = selected.where((s) => s.legacySuccess).toList();
    final selectedDiagnostics = selected
        .where((s) =>
            s.status == TrialStatus.failed || s.status == TrialStatus.review)
        .toList();
    final allFixed = group.where((s) => s.fixedWindowSuccess).toList();
    Set<String> ids(Iterable<TrialSummary> items) =>
        items.map((s) => s.id).toSet();

    return Scaffold(
      appBar: AppBar(title: Text('패턴 ${widget.pattern}')),
      body: SafeArea(
        top: false,
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Text(
                  '성공 ${group.where((s) => s.status == TrialStatus.success).length} · '
                  '실패 ${group.where((s) => s.status == TrialStatus.failed).length} · '
                  '검토 ${group.where((s) => s.status == TrialStatus.review).length}',
                  style: const TextStyle(fontWeight: FontWeight.w600),
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
                      ...TrialStatus.values
                    ])
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: ChoiceChip(
                          label:
                              Text(value == null ? '전체' : _statusName(value)),
                          selected: filter == value,
                          onSelected: (_) => setState(() => filter = value),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: shown.isEmpty
                          ? null
                          : () =>
                              _update(() => widget.selected.addAll(ids(shown))),
                      child: const Text('전체 선택'),
                    ),
                    TextButton(
                      onPressed: selected.isEmpty
                          ? null
                          : () => _update(
                              () => widget.selected.removeAll(ids(group))),
                      child: const Text('선택 해제'),
                    ),
                    Text('선택된 기록 ${selected.length}개',
                        style: const TextStyle(fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
            ),
            if (shown.isEmpty)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: Text('이 상태의 기록이 없습니다.'),
                ),
              )
            else
              SliverList.builder(
                itemCount: shown.length,
                itemBuilder: (context, index) {
                  final s = shown[index];
                  return Card(
                    key: Key('pattern_group_trial_${s.id}'),
                    margin:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                    child: Row(
                      children: [
                        Checkbox(
                          value: widget.selected.contains(s.id),
                          semanticLabel: '${shortTrialId(s.id)} 선택',
                          onChanged: (value) => _update(() {
                            if (value == true) {
                              widget.selected.add(s.id);
                            } else {
                              widget.selected.remove(s.id);
                            }
                          }),
                        ),
                        Expanded(
                          child: ListTile(
                            title: Text(
                              '${_timeLabel(s.createdAt, DateTime.now())} · ${_statusName(s.status)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: Text(
                              '실제 ${s.actualPattern} · 센서 ${s.mlRowCount}행\n'
                              'ID ${shortTrialId(s.id)}',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => _showTrial(s),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            SliverToBoxAdapter(
              child: Card(
                color: _pale,
                margin: const EdgeInsets.fromLTRB(12, 16, 12, 8),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text('이 패턴 데이터 업로드',
                          style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.bold,
                              color: _purple)),
                      const SizedBox(height: 4),
                      Text('Google Drive · 패턴 폴더 ${widget.pattern}'),
                      const SizedBox(height: 10),
                      FilledButton.icon(
                        key: const Key('pattern_group_primary_upload'),
                        onPressed: selectedFixed.isEmpty
                            ? null
                            : () => widget.onUpload(ids(selectedFixed), false),
                        icon: const Icon(Icons.cloud_upload_outlined),
                        label: Text('선택 ${selectedFixed.length}개 업로드'),
                      ),
                      if (selectedFixed.isEmpty)
                        const Text('선택한 고정창 성공 기록이 없습니다.',
                            style: TextStyle(fontSize: 12)),
                      if (selected.length != selectedFixed.length)
                        Text(
                            '선택된 구버전 ${selectedLegacy.length}건과 실패/검토 ${selectedDiagnostics.length}건은 기타 내보내기에서 분리해 처리합니다.',
                            style: const TextStyle(fontSize: 12)),
                    ],
                  ),
                ),
              ),
            ),
            SliverToBoxAdapter(
              child: Card(
                margin: const EdgeInsets.symmetric(horizontal: 12),
                child: ExpansionTile(
                  key: const Key('pattern_group_more_exports'),
                  title: const Text('기타 내보내기',
                      style: TextStyle(fontWeight: FontWeight.w600)),
                  children: [
                    ListTile(
                      title: Text('선택 고정창 성공 내보내기 (${selectedFixed.length})'),
                      onTap: selectedFixed.isEmpty
                          ? null
                          : () =>
                              widget.onExport(ids(selectedFixed), false, false),
                    ),
                    ListTile(
                      title: Text('선택 구버전 별도 내보내기 (${selectedLegacy.length})'),
                      onTap: selectedLegacy.isEmpty
                          ? null
                          : () =>
                              widget.onExport(ids(selectedLegacy), false, true),
                    ),
                    ListTile(
                      title:
                          Text('선택 실패/검토 내보내기 (${selectedDiagnostics.length})'),
                      onTap: selectedDiagnostics.isEmpty
                          ? null
                          : () => widget.onExport(
                              ids(selectedDiagnostics), true, false),
                    ),
                    ListTile(
                      title: const Text('이 패턴 전체 고정창 성공 내보내기'),
                      onTap: allFixed.isEmpty
                          ? null
                          : () => widget.onExport(ids(allFixed), false, false),
                    ),
                    ListTile(
                      title: const Text('이 패턴 전체 성공 Drive로 업로드'),
                      onTap: allFixed.isEmpty
                          ? null
                          : () => widget.onUpload(ids(allFixed), false),
                    ),
                    ListTile(
                      title: const Text('선택 실패/검토 Drive로 업로드'),
                      onTap: selectedDiagnostics.isEmpty
                          ? null
                          : () =>
                              widget.onUpload(ids(selectedDiagnostics), true),
                    ),
                  ],
                ),
              ),
            ),
            SliverPadding(
              padding: EdgeInsets.only(
                  bottom: 32 + MediaQuery.viewInsetsOf(context).bottom),
            ),
          ],
        ),
      ),
    );
  }
}
