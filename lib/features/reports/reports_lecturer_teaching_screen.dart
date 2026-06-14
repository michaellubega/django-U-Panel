import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/navigation/screen_refresh.dart';
import '../../core/theme/app_theme.dart';
import 'lecturer_teaching_roll_export.dart';
import '../attendance/attendance_list_hierarchy.dart';
import '../attendance/data/attendance_repository.dart';
import '../attendance/models/attendance_models.dart';
import '../attendance/roll_cell_status.dart';
import '../campus_presence/campus_presence_policy.dart';
import '../campus_presence/models/campus_presence_models.dart';
import '../lesson_insights/lesson_insights_models.dart';
import '../lesson_insights/lesson_insights_service.dart';
import '../lesson_insights/lesson_period_filter.dart';
import '../lesson_insights/lecturer_period_lessons_screen.dart';

String lecturerTeachingTimeRange(AttendanceSession session) {
  final s = session.startTime.toLocal();
  final e = session.endTime.toLocal();
  String t(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
  return '${t(s)}–${t(e)}';
}

String lecturerTeachingSessionDuration(AttendanceSession session) {
  return CampusPresencePolicy.formatDuration(
    session.endTime.difference(session.startTime),
  );
}

/// Lecturer teaching as an attendance-style roll (lecturers × dates).
class ReportsLecturerTeachingScreen extends StatefulWidget {
  const ReportsLecturerTeachingScreen({super.key});

  @override
  State<ReportsLecturerTeachingScreen> createState() =>
      _ReportsLecturerTeachingScreenState();
}

class _ReportsLecturerTeachingScreenState
    extends State<ReportsLecturerTeachingScreen> {
  LessonPeriodFilter _filter = LessonPeriodFilter.week;
  DateTime _anchor = DateTime.now();
  bool _loading = true;
  bool _exportBusy = false;
  RollPendingContext _pending = const RollPendingContext.empty();
  List<LessonSessionInsight> _insights = const [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
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
      );
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickAnchorDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _anchor,
      firstDate: DateTime(2024),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked == null) return;
    setState(() => _anchor = picked);
    await _reload();
  }

  Future<void> _exportPdf() async {
    setState(() => _exportBusy = true);
    try {
      final path = await exportLecturerTeachingRollPdf(
        filter: _filter,
        anchor: _anchor,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            path != null
                ? 'PDF saved to $path'
                : 'PDF downloaded to your device',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not save PDF: $e')),
      );
    } finally {
      if (mounted) setState(() => _exportBusy = false);
    }
  }

  List<String> _dateKeysInRange() {
    final (start, end) = _filter.dateRange(_anchor);
    final keys = <String>[];
    var day = start;
    while (!day.isAfter(end)) {
      keys.add(localDateKeyFor(day));
      day = day.add(const Duration(days: 1));
    }
    return keys.reversed.toList();
  }

  int _totalClassesFor(
    String lecturerName,
    Map<String, Map<String, List<LessonSessionInsight>>> cellMap,
  ) {
    final byDate = cellMap[lecturerName];
    if (byDate == null) return 0;
    return byDate.values.fold<int>(0, (sum, sessions) => sum + sessions.length);
  }

  String? _latestTeachingKey(
    String lecturerName,
    Map<String, Map<String, List<LessonSessionInsight>>> cellMap,
  ) {
    final byDate = cellMap[lecturerName];
    if (byDate == null || byDate.isEmpty) return null;
    final keys = byDate.entries
        .where((e) => e.value.isNotEmpty)
        .map((e) => e.key)
        .toList()
      ..sort((a, b) => b.compareTo(a));
    return keys.isEmpty ? null : keys.first;
  }

  List<String> _sortedLecturers(
    List<String> roster,
    Map<String, Map<String, List<LessonSessionInsight>>> cellMap,
  ) {
    final copy = [...roster];
    copy.sort((a, b) {
      final latestA = _latestTeachingKey(a, cellMap);
      final latestB = _latestTeachingKey(b, cellMap);
      if (latestA != null && latestB != null) {
        final byDate = latestB.compareTo(latestA);
        if (byDate != 0) return byDate;
      } else if (latestA != null) {
        return -1;
      } else if (latestB != null) {
        return 1;
      }
      return a.toLowerCase().compareTo(b.toLowerCase());
    });
    return copy;
  }

  List<String> _lecturerRoster() {
    final names = <String>{};
    for (final list in AttendanceStore.lists) {
      if (!attendanceListVisibleInHierarchy(list)) continue;
      final name = LessonInsightsService.lecturerNameForList(list);
      if (name.isNotEmpty) names.add(name);
    }
    final roster = names.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return roster;
  }

  Map<String, Map<String, List<LessonSessionInsight>>> _sessionsByLecturerAndDate() {
    final map = <String, Map<String, List<LessonSessionInsight>>>{};
    for (final insight in _insights) {
      final dateKey = localDateKeyFor(insight.lessonDate);
      final byDate = map.putIfAbsent(insight.lecturerName, () => {});
      (byDate[dateKey] ??= []).add(insight);
    }
    for (final byDate in map.values) {
      for (final sessions in byDate.values) {
        sessions.sort(
          (a, b) => a.session.startTime.compareTo(b.session.startTime),
        );
      }
    }
    return map;
  }

  void _openLecturerDetail(String lecturerName) {
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => LecturerPeriodLessonsScreen(
          lecturerName: lecturerName,
          filter: _filter,
          anchor: _anchor,
        ),
      ),
    );
  }

  String _periodTitle(MaterialLocalizations loc) {
    final (start, end) = _filter.dateRange(_anchor);
    switch (_filter) {
      case LessonPeriodFilter.day:
        return loc.formatFullDate(_anchor);
      case LessonPeriodFilter.week:
        return '${loc.formatShortDate(start)} – ${loc.formatShortDate(end)}';
      case LessonPeriodFilter.month:
        return '${_monthName(_anchor.month)} ${_anchor.year}';
    }
  }

  static String _monthName(int month) {
    const names = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    return names[month - 1];
  }

  String _fmtDateKey(String key) {
    final d = CampusPresencePolicy.dateFromLocalDateKey(key);
    if (d == null) return key;
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loc = MaterialLocalizations.of(context);
    final dateKeys = _dateKeysInRange();
    final cellMap = _sessionsByLecturerAndDate();
    final lecturers = _sortedLecturers(_lecturerRoster(), cellMap);
    final lessonDays = cellMap.values
        .expand((m) => m.entries)
        .where((e) => e.value.isNotEmpty)
        .length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Lecturer teaching'),
        actions: [
          RefreshIconButton(onRefresh: _reload),
          IconButton(
            tooltip: 'Export PDF',
            onPressed: _exportBusy ? null : _exportPdf,
            icon: _exportBusy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.picture_as_pdf_rounded),
          ),
          IconButton(
            tooltip: 'Pick date',
            onPressed: _pickAnchorDate,
            icon: const Icon(Icons.calendar_today_rounded),
          ),
        ],
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: SegmentedButton<LessonPeriodFilter>(
              segments: [
                for (final f in LessonPeriodFilter.values)
                  ButtonSegment(value: f, label: Text(f.label)),
              ],
              selected: {_filter},
              onSelectionChanged: (s) {
                setState(() => _filter = s.first);
                unawaited(_reload());
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Text(
              _periodTitle(loc),
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _reload,
              child: _loading
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
                          padding: const EdgeInsets.all(24),
                          children: [
                            Text(
                              'No lecturers on attendance lists yet.',
                              style: theme.textTheme.bodyLarge?.copyWith(
                                color: AppTheme.textSecondary,
                              ),
                            ),
                          ],
                        )
                      : ListView(
                          physics: kRefreshScrollPhysics,
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                          children: [
                            _LecturerTeachingRollSummary(
                              lecturerCount: lecturers.length,
                              dateCount: dateKeys.length,
                              lessonCount: _insights.length,
                              lessonDays: lessonDays,
                            ),
                            const SizedBox(height: 16),
                            Card(
                              clipBehavior: Clip.antiAlias,
                              child: SingleChildScrollView(
                                scrollDirection: Axis.horizontal,
                                child: DataTable(
                                  headingRowHeight: 44,
                                  dataRowMinHeight: 72,
                                  dataRowMaxHeight: 120,
                                  columnSpacing: 12,
                                  columns: [
                                    const DataColumn(
                                      label: Text(
                                        'Lecturer',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                    const DataColumn(
                                      label: Text(
                                        'Period totals',
                                        style: TextStyle(
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ),
                                    for (final key in dateKeys)
                                      DataColumn(
                                        label: Text(
                                          _fmtDateKey(key),
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                          ),
                                        ),
                                      ),
                                  ],
                                  rows: [
                                    for (final name in lecturers)
                                      DataRow(
                                        onSelectChanged: (_) =>
                                            _openLecturerDetail(name),
                                        cells: [
                                          DataCell(
                                            SizedBox(
                                              width: 160,
                                              child: Text(
                                                name,
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  fontWeight: FontWeight.w600,
                                                ),
                                              ),
                                            ),
                                          ),
                                          DataCell(
                                            SizedBox(
                                              width: 100,
                                              child: _LecturerPeriodTotalsCell(
                                                classCount: _totalClassesFor(
                                                  name,
                                                  cellMap,
                                                ),
                                              ),
                                            ),
                                          ),
                                          for (final key in dateKeys)
                                            DataCell(
                                              SizedBox(
                                                width: 118,
                                                child: _LecturerTeachingRollCell(
                                                  sessions: cellMap[name]?[key],
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LecturerPeriodTotalsCell extends StatelessWidget {
  const _LecturerPeriodTotalsCell({required this.classCount});

  final int classCount;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          '$classCount',
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            color: AppTheme.primary,
          ),
        ),
        Text(
          classCount == 1 ? 'class taught' : 'classes taught',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppTheme.textSecondary,
                fontWeight: FontWeight.w600,
                fontSize: 10,
              ),
        ),
      ],
    );
  }
}

class _LecturerTeachingRollSummary extends StatelessWidget {
  const _LecturerTeachingRollSummary({
    required this.lecturerCount,
    required this.dateCount,
    required this.lessonCount,
    required this.lessonDays,
  });

  final int lecturerCount;
  final int dateCount;
  final int lessonCount;
  final int lessonDays;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppTheme.background,
            AppTheme.accentLight.withValues(alpha: 0.4),
          ],
        ),
        border: Border.all(color: AppTheme.primary.withValues(alpha: 0.12)),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          _chip(theme, Icons.person_rounded, '$lecturerCount lecturers'),
          _chip(theme, Icons.date_range_rounded, '$dateCount days'),
          _chip(
            theme,
            Icons.menu_book_rounded,
            '$lessonCount lessons',
            color: AppTheme.primary,
          ),
          _chip(
            theme,
            Icons.event_available_rounded,
            '$lessonDays taught',
            color: AppTheme.success,
          ),
        ],
      ),
    );
  }

  Widget _chip(
    ThemeData theme,
    IconData icon,
    String label, {
    Color? color,
  }) {
    final c = color ?? AppTheme.primary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.softGrey.withValues(alpha: 0.85)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: c),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _LecturerTeachingRollCell extends StatelessWidget {
  const _LecturerTeachingRollCell({this.sessions});

  final List<LessonSessionInsight>? sessions;

  @override
  Widget build(BuildContext context) {
    if (sessions == null || sessions!.isEmpty) {
      return Text(
        'No class',
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: AppTheme.textSecondary,
              fontWeight: FontWeight.w600,
            ),
      );
    }

    final items = sessions!;
    if (items.length == 1) {
      final insight = items.first;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            lecturerTeachingTimeRange(insight.session),
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AppTheme.primary,
            ),
          ),
          Text(
            insight.list.room.isNotEmpty ? insight.list.room : insight.courseLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 11,
              color: AppTheme.textSecondary,
            ),
          ),
          Text(
            lecturerTeachingSessionDuration(insight.session),
            style: const TextStyle(
              fontSize: 10,
              color: AppTheme.textSecondary,
            ),
          ),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          '${items.length} lessons',
          style: const TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: AppTheme.primary,
          ),
        ),
        for (final insight in items.take(2)) ...[
          Text(
            '${lecturerTeachingTimeRange(insight.session)} · ${insight.list.room.isNotEmpty ? insight.list.room : insight.courseLabel}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 10,
              color: AppTheme.textSecondary,
            ),
          ),
        ],
        if (items.length > 2)
          Text(
            '+${items.length - 2} more',
            style: const TextStyle(
              fontSize: 10,
              color: AppTheme.textSecondary,
            ),
          ),
      ],
    );
  }
}
