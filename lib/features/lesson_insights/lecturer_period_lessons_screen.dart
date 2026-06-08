import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/navigation/screen_refresh.dart';
import '../../core/theme/app_theme.dart';
import '../attendance/data/attendance_repository.dart';
import '../attendance/roll_cell_status.dart';
import 'lesson_insights_models.dart';
import 'lesson_insights_service.dart';
import 'lesson_insights_widgets.dart';
import 'lesson_period_filter.dart';
import 'lesson_session_detail_screen.dart';

/// Lessons for one lecturer within a day / week / month period.
class LecturerPeriodLessonsScreen extends StatefulWidget {
  const LecturerPeriodLessonsScreen({
    super.key,
    required this.lecturerName,
    required this.filter,
    required this.anchor,
    this.lecturerScopeOnly = false,
  });

  final String lecturerName;
  final LessonPeriodFilter filter;
  final DateTime anchor;

  /// When true, only sessions for the signed-in lecturer's lists are shown.
  final bool lecturerScopeOnly;

  @override
  State<LecturerPeriodLessonsScreen> createState() =>
      _LecturerPeriodLessonsScreenState();
}

class _LecturerPeriodLessonsScreenState
    extends State<LecturerPeriodLessonsScreen> {
  bool _loading = true;
  RollPendingContext _pending = const RollPendingContext.empty();
  List<LessonSessionInsight> _insights = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_reload());
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    try {
      await AttendanceRepository.instance.loadAll(
        force: !AttendanceRepository.instance.hasCachedStore,
        scopeToLecturerUid: AttendanceRepository.currentLecturerLoadScopeUid(),
      );
      _pending = await RollPendingContext.load();
      final all = LessonInsightsService.insightsInPeriod(
        _pending,
        filter: widget.filter,
        anchor: widget.anchor,
        lecturerScopeOnly: widget.lecturerScopeOnly,
      );
      final nameKey =
          LessonInsightsService.normalizeLecturerName(widget.lecturerName)
              .toLowerCase();
      _insights = all
          .where(
            (i) =>
                LessonInsightsService.normalizeLecturerName(i.lecturerName)
                    .toLowerCase() ==
                nameKey,
          )
          .toList();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _openDetail(LessonSessionInsight insight) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => LessonSessionDetailScreen(insight: insight),
      ),
    );
  }

  Map<DateTime, List<LessonSessionInsight>> get _byDay {
    final map = <DateTime, List<LessonSessionInsight>>{};
    for (final i in _insights) {
      (map[i.lessonDate] ??= []).add(i);
    }
    for (final list in map.values) {
      list.sort((a, b) => a.session.startTime.compareTo(b.session.startTime));
    }
    return map;
  }

  @override
  Widget build(BuildContext context) {
    final days = _byDay.keys.toList()..sort((a, b) => b.compareTo(a));
    var present = 0;
    var absent = 0;
    var pending = 0;
    var enrolled = 0;
    for (final i in _insights) {
      present += i.roll.present;
      absent += i.roll.absent;
      pending += i.roll.pending;
      enrolled += i.roll.enrolled;
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.lecturerName),
        actions: [
          RefreshIconButton(onRefresh: _reload),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: ListView(
          physics: kRefreshScrollPhysics,
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          children: [
            Text(
              widget.filter.describeRange(widget.anchor),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppTheme.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 12),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 48),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_insights.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 32),
                child: Text(
                  'No lessons for this lecturer in this period.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        color: AppTheme.textSecondary,
                      ),
                ),
              )
            else ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppTheme.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(14),
                  border:
                      Border.all(color: AppTheme.primary.withValues(alpha: 0.2)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${_insights.length} ${_insights.length == 1 ? 'lesson' : 'lessons'}',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                            color: AppTheme.primary,
                          ),
                    ),
                    const SizedBox(height: 8),
                    LessonRollCountRow(
                      roll: LessonSessionRollCounts(
                        enrolled: enrolled,
                        present: present,
                        absent: absent,
                        pending: pending,
                      ),
                      compact: true,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              if (widget.filter == LessonPeriodFilter.day)
                for (final insight in _insights)
                  LessonSessionInsightCard(
                    insight: insight,
                    onTap: () => _openDetail(insight),
                  )
              else
                for (final day in days) ...[
                  _dayHeader(day, _byDay[day]!.length),
                  for (final insight in _byDay[day]!)
                    LessonSessionInsightCard(
                      insight: insight,
                      onTap: () => _openDetail(insight),
                    ),
                  const SizedBox(height: 8),
                ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _dayHeader(DateTime day, int count) {
    final label =
        '${day.day.toString().padLeft(2, '0')}/${day.month.toString().padLeft(2, '0')}/${day.year}';
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: Text(
        '$label · $count ${count == 1 ? 'lesson' : 'lessons'}',
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: AppTheme.secondary,
            ),
      ),
    );
  }
}
