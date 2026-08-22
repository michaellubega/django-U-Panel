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
import 'lecturer_period_lessons_screen.dart';

/// QA / admin: lecturers who taught on a specific day, with session detail.
class QaLecturersOnDayScreen extends StatefulWidget {
  const QaLecturersOnDayScreen({
    super.key,
    required this.day,
  });

  final DateTime day;

  @override
  State<QaLecturersOnDayScreen> createState() => _QaLecturersOnDayScreenState();
}

class _QaLecturersOnDayScreenState extends State<QaLecturersOnDayScreen> {
  bool _loading = true;
  final _searchC = TextEditingController();
  RollPendingContext _pending = const RollPendingContext.empty();
  List<LessonSessionInsight> _all = const [];
  String _query = '';

  @override
  void initState() {
    super.initState();
    _searchC.addListener(() => setState(() => _query = _searchC.text.trim()));
    unawaited(_reload());
  }

  @override
  void dispose() {
    _searchC.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    setState(() => _loading = true);
    try {
      await AttendanceRepository.instance.loadAll(
        force: !AttendanceRepository.instance.hasCachedStore,
        scopeToLecturerUid: AttendanceRepository.currentLecturerLoadScopeUid(),
      );
      _pending = await RollPendingContext.load();
      _all = LessonInsightsService.insightsOnDay(
        _pending,
        day: widget.day,
      );
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

  void _openLecturerPeriod(String name) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => LecturerPeriodLessonsScreen(
          lecturerName: name,
          filter: LessonPeriodFilter.day,
          anchor: widget.day,
        ),
      ),
    );
  }

  String get _dayLabel {
    final d = widget.day;
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  }

  List<LessonSessionInsight> get _filtered {
    if (_query.isEmpty) return _all;
    final q = _query.toLowerCase();
    return _all.where((i) {
      return i.lecturerName.toLowerCase().contains(q) ||
          i.list.room.toLowerCase().contains(q) ||
          i.courseLabel.toLowerCase().contains(q) ||
          i.list.whoTaught.toLowerCase().contains(q) ||
          i.yearSemLabel.toLowerCase().contains(q);
    }).toList();
  }

  Map<String, List<LessonSessionInsight>> get _byLecturer {
    final map = <String, List<LessonSessionInsight>>{};
    for (final i in _filtered) {
      (map[i.lecturerName] ??= []).add(i);
    }
    for (final list in map.values) {
      list.sort((a, b) => a.session.startTime.compareTo(b.session.startTime));
    }
    return map;
  }

  @override
  Widget build(BuildContext context) {
    final lecturers = _byLecturer.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    return Scaffold(
      appBar: AppBar(
        title: Text('Lecturers · $_dayLabel'),
        actions: [
          RefreshIconButton(onRefresh: _reload),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: TextField(
              controller: _searchC,
              decoration: InputDecoration(
                hintText: 'Search lecturer, room, course…',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _query.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear_rounded),
                        onPressed: () => _searchC.clear(),
                      )
                    : null,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                isDense: true,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Text(
                  '${_filtered.length} lessons · ${lecturers.length} lecturers',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppTheme.textSecondary,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _reload,
              child: _loading && lecturers.isEmpty
                  ? ListView(
                      physics: kRefreshScrollPhysics,
                      children: const [
                        SizedBox(height: 120),
                        Center(child: CircularProgressIndicator()),
                      ],
                    )
                  : lecturers.isEmpty
                      ? ListView(
                          physics: kRefreshScrollPhysics,
                          children: [
                              Padding(
                                padding: const EdgeInsets.all(32),
                                child: Text(
                                  _query.isEmpty
                                      ? 'No lessons on this day.'
                                      : 'No lecturers match your search.',
                                  textAlign: TextAlign.center,
                                  style: Theme.of(context)
                                      .textTheme
                                      .bodyLarge
                                      ?.copyWith(
                                        color: AppTheme.textSecondary,
                                      ),
                                ),
                              ),
                            ],
                          )
                        : ListView.builder(
                            physics: kRefreshScrollPhysics,
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                            itemCount: lecturers.length,
                            itemBuilder: (context, index) {
                              final name = lecturers[index];
                              final sessions = _byLecturer[name]!;
                              return _lecturerSection(name, sessions);
                            },
                          ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _lecturerSection(String name, List<LessonSessionInsight> sessions) {
    var present = 0;
    var absent = 0;
    var pending = 0;
    var enrolled = 0;
    for (final s in sessions) {
      present += s.roll.present;
      absent += s.roll.absent;
      pending += s.roll.pending;
      enrolled += s.roll.enrolled;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 8),
          child: Material(
            color: AppTheme.primary.withValues(alpha: 0.08),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(color: AppTheme.primary.withValues(alpha: 0.2)),
            ),
            child: InkWell(
              onTap: () => _openLecturerPeriod(name),
              borderRadius: BorderRadius.circular(14),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            name,
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(
                                  fontWeight: FontWeight.w800,
                                  color: AppTheme.primary,
                                ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${sessions.length} ${sessions.length == 1 ? 'lesson' : 'lessons'} today',
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: AppTheme.textSecondary,
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
                    const Icon(Icons.chevron_right_rounded,
                        color: AppTheme.primary),
                  ],
                ),
              ),
            ),
          ),
        ),
        for (final insight in sessions)
          LessonSessionInsightCard(
            insight: insight,
            onTap: () => _openDetail(insight),
          ),
      ],
    );
  }
}
