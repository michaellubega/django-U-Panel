import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/navigation/screen_refresh.dart';
import '../../core/theme/app_theme.dart';
import '../attendance/data/attendance_repository.dart';
import '../attendance/models/attendance_models.dart';
import '../attendance/roll_cell_status.dart';
import 'lesson_insights_models.dart';
import 'lesson_insights_service.dart';
import 'lesson_insights_widgets.dart';

/// Full roll breakdown for one taught session.
class LessonSessionDetailScreen extends StatefulWidget {
  const LessonSessionDetailScreen({
    super.key,
    required this.insight,
  });

  final LessonSessionInsight insight;

  @override
  State<LessonSessionDetailScreen> createState() =>
      _LessonSessionDetailScreenState();
}

class _LessonSessionDetailScreenState extends State<LessonSessionDetailScreen> {
  bool _loading = true;
  RollPendingContext _pending = const RollPendingContext.empty();

  LessonSessionInsight get _insight => widget.insight;

  @override
  void initState() {
    super.initState();
    AttendanceRepository.instance.addListener(_onStoreChanged);
    unawaited(_reload());
  }

  @override
  void dispose() {
    AttendanceRepository.instance.removeListener(_onStoreChanged);
    super.dispose();
  }

  void _onStoreChanged() {
    if (!mounted || _loading) return;
    setState(() {});
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    try {
      await AttendanceRepository.instance.loadAll(
        force: !AttendanceRepository.instance.hasCachedStore,
        scopeToLecturerUid: AttendanceRepository.currentLecturerLoadScopeUid(),
      );
      _pending = await RollPendingContext.load();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _timeRange(AttendanceSession session) {
    final s = session.startTime.toLocal();
    final e = session.endTime.toLocal();
    String t(DateTime d) =>
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
    return '${t(s)} – ${t(e)}';
  }

  List<({StudentRecord student, String? label})> _studentRows() {
    final session = _insight.session;
    final list = _insight.list;
    final studentsById = AttendanceStore.rosterStudentMapForList(list.id);
    final studentIds = AttendanceStore.studentIdsSignedIntoList(list.id);
    final rows = <({StudentRecord student, String? label})>[];
    for (final sid in studentIds) {
      final student = studentsById[sid];
      if (student == null) continue;
      final records = AttendanceStore.attendanceRecords
          .where((r) => r.studentId == sid)
          .toList();
      final label = rollCellLabelForStudentSession(
        session: session,
        studentId: sid,
        recordsForStudent: records,
        pending: _pending,
      );
      rows.add((student: student, label: label));
    }
    rows.sort((a, b) {
      final order = _labelOrder(a.label).compareTo(_labelOrder(b.label));
      if (order != 0) return order;
      return a.student.name.toLowerCase().compareTo(b.student.name.toLowerCase());
    });
    return rows;
  }

  int _labelOrder(String? label) => switch (label) {
        kRollLabelPresent => 0,
        kRollLabelPending => 1,
        kRollLabelAbsent => 2,
        _ => 3,
      };

  Color _labelColor(String? label) => switch (label) {
        kRollLabelPresent => AppTheme.success,
        kRollLabelAbsent => AppTheme.error,
        kRollLabelPending => AppTheme.warning,
        _ => AppTheme.textSecondary,
      };

  @override
  Widget build(BuildContext context) {
    final insight = _insight;
    final roll = LessonInsightsService.rollCountsForSession(
      insight.session,
      insight.list,
      _pending,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('Lesson detail'),
        actions: [
          RefreshIconButton(onRefresh: _reload),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: _loading
            ? ListView(
                physics: kRefreshScrollPhysics,
                children: const [
                  SizedBox(height: 120),
                  Center(child: CircularProgressIndicator()),
                ],
              )
            : ListView(
                physics: kRefreshScrollPhysics,
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                children: [
                  LessonSessionInsightCard(insight: insight.copyWithRoll(roll)),
                  const SizedBox(height: 8),
                  Text(
                    'Lecturer: ${insight.lecturerName}',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: AppTheme.textSecondary,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                  Text(
                    '${_timeRange(insight.session)} · Room ${insight.list.room}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppTheme.textSecondary,
                        ),
                  ),
                  const SizedBox(height: 20),
                  Text(
                    'Student roll',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  const SizedBox(height: 8),
                  ..._studentRows().map(_studentTile),
                ],
              ),
      ),
    );
  }

  Widget _studentTile(({StudentRecord student, String? label}) row) {
    final label = row.label ?? '—';
    final color = _labelColor(row.label);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        title: Text(
          row.student.name,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(row.student.registrationNumber),
        trailing: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: color.withValues(alpha: 0.35)),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
        ),
      ),
    );
  }
}

extension on LessonSessionInsight {
  LessonSessionInsight copyWithRoll(LessonSessionRollCounts roll) {
    return LessonSessionInsight(
      session: session,
      list: list,
      lecturerName: lecturerName,
      roll: roll,
    );
  }
}
