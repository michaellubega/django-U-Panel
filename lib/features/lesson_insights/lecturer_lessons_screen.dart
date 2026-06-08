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

/// Lecturer view: sessions they taught with onboarded students.
class LecturerLessonsScreen extends StatefulWidget {
  const LecturerLessonsScreen({super.key});

  @override
  State<LecturerLessonsScreen> createState() => _LecturerLessonsScreenState();
}

class _LecturerLessonsScreenState extends State<LecturerLessonsScreen> {
  bool _loading = true;
  LessonPeriodFilter _filter = LessonPeriodFilter.day;
  DateTime _anchor = DateTime.now();
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
      _insights = LessonInsightsService.insightsInPeriod(
        _pending,
        filter: _filter,
        anchor: _anchor,
        lecturerScopeOnly: true,
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _setFilter(LessonPeriodFilter f) {
    setState(() => _filter = f);
    unawaited(_reload());
  }

  void _setAnchor(DateTime d) {
    setState(() => _anchor = d);
    unawaited(_reload());
  }

  void _openDetail(LessonSessionInsight insight) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => LessonSessionDetailScreen(insight: insight),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final grouped = LessonInsightsService.groupByList(_insights);
    final listIds = grouped.keys.toList()
      ..sort((a, b) {
        final la = grouped[a]!.first.list;
        final lb = grouped[b]!.first.list;
        return la.displayTitle.toLowerCase().compareTo(lb.displayTitle.toLowerCase());
      });

    return Scaffold(
      appBar: AppBar(
        title: const Text('My lessons'),
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
              'Sessions for classes with enrolled students',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppTheme.textSecondary,
                  ),
            ),
            const SizedBox(height: 16),
            LessonPeriodFilterBar(
              filter: _filter,
              anchorDate: _anchor,
              onFilterChanged: _setFilter,
              onAnchorChanged: _setAnchor,
            ),
            const SizedBox(height: 16),
            _summaryHeader(_insights.length, grouped.length),
            const SizedBox(height: 16),
            if (_loading)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 48),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_insights.isEmpty)
              _emptyState(context)
            else
              for (final listId in listIds) ...[
                _listSectionHeader(grouped[listId]!.first),
                for (final insight in grouped[listId]!)
                  LessonSessionInsightCard(
                    insight: insight,
                    onTap: () => _openDetail(insight),
                  ),
                const SizedBox(height: 8),
              ],
          ],
        ),
      ),
    );
  }

  Widget _summaryHeader(int sessions, int classes) {
    return Row(
      children: [
        Expanded(
          child: _statBox('Lessons', '$sessions', AppTheme.primary),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: _statBox('Classes', '$classes', AppTheme.secondary),
        ),
      ],
    );
  }

  Widget _statBox(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _listSectionHeader(LessonSessionInsight sample) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 4),
      child: Text(
        sample.list.displayTitle,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: AppTheme.primary,
            ),
      ),
    );
  }

  Widget _emptyState(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Column(
        children: [
          Icon(Icons.event_busy_rounded,
              size: 48, color: AppTheme.textSecondary.withValues(alpha: 0.6)),
          const SizedBox(height: 12),
          Text(
            'No lessons in this period',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            'Lessons appear after you run a session for a class that has enrolled students.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppTheme.textSecondary,
                ),
          ),
        ],
      ),
    );
  }
}
