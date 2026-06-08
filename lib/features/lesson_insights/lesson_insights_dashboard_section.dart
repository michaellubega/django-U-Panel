import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';
import '../attendance/roll_cell_status.dart';
import 'lesson_insights_service.dart';
import 'lesson_period_filter.dart';
import 'lecturer_lessons_screen.dart';
import 'qa_lesson_activity_screen.dart';
import 'qa_lecturers_on_day_screen.dart';
import '../dashboard/dashboard_shared_widgets.dart';

/// Compact lesson summary for QA / admin dashboard.
class QaLessonInsightsDashboardCard extends StatefulWidget {
  const QaLessonInsightsDashboardCard({super.key});

  @override
  State<QaLessonInsightsDashboardCard> createState() =>
      _QaLessonInsightsDashboardCardState();
}

class _QaLessonInsightsDashboardCardState
    extends State<QaLessonInsightsDashboardCard> {
  LessonPeriodFilter _filter = LessonPeriodFilter.day;
  DateTime _anchor = DateTime.now();
  RollPendingContext _pending = const RollPendingContext.empty();
  int _lessonCount = 0;
  int _lecturerCount = 0;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    unawaited(_recompute());
  }

  Future<void> _recompute() async {
    _pending = await RollPendingContext.load();
    final insights = LessonInsightsService.insightsInPeriod(
      _pending,
      filter: _filter,
      anchor: _anchor,
    );
    final lecturers = LessonInsightsService.lecturerAggregates(insights);
    if (!mounted) return;
    setState(() {
      _lessonCount = insights.length;
      _lecturerCount = lecturers.length;
      _ready = true;
    });
  }

  void _openActivity() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => const QaLessonActivityScreen(),
      ),
    );
  }

  void _openTodayDetail() {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => QaLecturersOnDayScreen(day: _anchor),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                'Lecturer lessons',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
            ),
            TextButton.icon(
              onPressed: _openActivity,
              icon: const Icon(Icons.open_in_new_rounded, size: 18),
              label: const Text('All lecturers'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LessonPeriodFilterBar(
                  filter: _filter,
                  anchorDate: _anchor,
                  onFilterChanged: (f) {
                    setState(() => _filter = f);
                    unawaited(_recompute());
                  },
                  onAnchorChanged: (d) {
                    setState(() => _anchor = d);
                    unawaited(_recompute());
                  },
                ),
                const SizedBox(height: 16),
                if (!_ready)
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.all(12),
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                else
                  Row(
                    children: [
                      Expanded(
                        child: _metric(
                          context,
                          'Lessons',
                          '$_lessonCount',
                          AppTheme.primary,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _metric(
                          context,
                          'Lecturers',
                          '$_lecturerCount',
                          AppTheme.secondary,
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: 12),
                FilledButton.tonalIcon(
                  onPressed: _filter == LessonPeriodFilter.day
                      ? _openTodayDetail
                      : _openActivity,
                  icon: Icon(
                    _filter == LessonPeriodFilter.day
                        ? Icons.groups_rounded
                        : Icons.person_search_rounded,
                  ),
                  label: Text(
                    _filter == LessonPeriodFilter.day
                        ? 'Lecturers on ${_filter.describeRange(_anchor)}'
                        : 'Browse lecturers (${_filter.label.toLowerCase()})',
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _metric(
    BuildContext context,
    String label,
    String value,
    Color color,
  ) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
          ),
          Text(
            value,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: color,
                ),
          ),
        ],
      ),
    );
  }
}

/// One-line lesson count for lecturer home (month scope).
class LecturerLessonsDashboardTile extends StatefulWidget {
  const LecturerLessonsDashboardTile({super.key});

  @override
  State<LecturerLessonsDashboardTile> createState() =>
      _LecturerLessonsDashboardTileState();
}

class _LecturerLessonsDashboardTileState
    extends State<LecturerLessonsDashboardTile> {
  int _monthLessons = 0;
  int _todayLessons = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final pending = await RollPendingContext.load();
    final now = DateTime.now();
    final today = LessonInsightsService.insightsOnDay(
      pending,
      day: now,
      lecturerScopeOnly: true,
    );
    final week = LessonInsightsService.insightsInPeriod(
      pending,
      filter: LessonPeriodFilter.week,
      anchor: now,
      lecturerScopeOnly: true,
    );
    if (!mounted) return;
    setState(() {
      _monthLessons = week.length;
      _todayLessons = today.length;
    });
  }

  @override
  Widget build(BuildContext context) {
    return DashboardQuickAction(
      icon: Icons.history_edu_rounded,
      label: 'My lessons',
      subtitle:
          'Today $_todayLessons · This week $_monthLessons (enrolled classes)',
      onTap: () {
        Navigator.of(context).push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const LecturerLessonsScreen(),
          ),
        );
      },
    );
  }
}
