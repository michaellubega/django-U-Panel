import '../attendance/attendance_list_hierarchy.dart';
import '../attendance/data/attendance_repository.dart';
import '../attendance/models/attendance_models.dart';
import '../attendance/roll_cell_status.dart';
import '../campus_presence/campus_presence_grouping.dart';
import '../campus_presence/campus_presence_policy.dart';
import '../campus_presence/models/campus_presence_models.dart';
import '../lesson_insights/lesson_insights_models.dart';
import '../lesson_insights/lesson_insights_service.dart';
import '../lesson_insights/lesson_period_filter.dart';
import 'reports_roll_pdf.dart';
import 'reports_lecturer_teaching_screen.dart';

class LecturerTeachingRollExportRow {
  const LecturerTeachingRollExportRow({
    required this.lecturerName,
    required this.classCount,
    required this.cellsByDateKey,
  });

  final String lecturerName;
  final int classCount;
  final Map<String, String> cellsByDateKey;
}

class LecturerTeachingRollExportData {
  const LecturerTeachingRollExportData({
    required this.periodLabel,
    required this.dateKeys,
    required this.rows,
  });

  final String periodLabel;
  final List<String> dateKeys;
  final List<LecturerTeachingRollExportRow> rows;
}

List<String> _dateKeysRecentFirst(LessonPeriodFilter filter, DateTime anchor) {
  final (start, end) = filter.dateRange(anchor);
  final keys = <String>[];
  var day = start;
  while (!day.isAfter(end)) {
    keys.add(localDateKeyFor(day));
    day = day.add(const Duration(days: 1));
  }
  return keys.reversed.toList();
}

List<String> _lecturerRoster() {
  final names = <String>{};
  for (final list in AttendanceStore.lists) {
    if (!attendanceListVisibleInHierarchy(list)) continue;
    final name = LessonInsightsService.lecturerNameForList(list);
    if (name.isNotEmpty) names.add(name);
  }
  return names.toList();
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

int _totalClassesFor(
  String lecturerName,
  Map<String, Map<String, List<LessonSessionInsight>>> cellMap,
) {
  final byDate = cellMap[lecturerName];
  if (byDate == null) return 0;
  return byDate.values.fold<int>(0, (sum, sessions) => sum + sessions.length);
}

String _lecturerCellText(List<LessonSessionInsight>? sessions) {
  if (sessions == null || sessions.isEmpty) return 'No class';
  if (sessions.length == 1) {
    final insight = sessions.first;
    return [
      lecturerTeachingTimeRange(insight.session),
      insight.list.room.isNotEmpty ? insight.list.room : insight.courseLabel,
      lecturerTeachingSessionDuration(insight.session),
    ].join('\n');
  }
  final lines = <String>['${sessions.length} lessons'];
  for (final insight in sessions.take(3)) {
    lines.add(
      '${lecturerTeachingTimeRange(insight.session)} · ${insight.list.room.isNotEmpty ? insight.list.room : insight.courseLabel}',
    );
  }
  if (sessions.length > 3) lines.add('+${sessions.length - 3} more');
  return lines.join('\n');
}

String _fmtDateKey(String key) {
  final d = CampusPresencePolicy.dateFromLocalDateKey(key);
  if (d == null) return key;
  return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';
}

Future<LecturerTeachingRollExportData> loadLecturerTeachingRollExport({
  required LessonPeriodFilter filter,
  required DateTime anchor,
}) async {
  await AttendanceRepository.instance.loadAll(
    force: !AttendanceRepository.instance.hasCachedStore,
    scopeToLecturerUid: AttendanceRepository.currentLecturerLoadScopeUid(),
  );
  final pending = await RollPendingContext.load();
  final insights = LessonInsightsService.insightsInPeriod(
    pending,
    filter: filter,
    anchor: anchor,
  );

  final cellMap = <String, Map<String, List<LessonSessionInsight>>>{};
  for (final insight in insights) {
    final dateKey = localDateKeyFor(insight.lessonDate);
    final byDate = cellMap.putIfAbsent(insight.lecturerName, () => {});
    (byDate[dateKey] ??= []).add(insight);
  }
  for (final byDate in cellMap.values) {
    for (final sessions in byDate.values) {
      sessions.sort(
        (a, b) => a.session.startTime.compareTo(b.session.startTime),
      );
    }
  }

  final dateKeys = _dateKeysRecentFirst(filter, anchor);
  final roster = _lecturerRoster()
    ..sort((a, b) {
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

  final rows = <LecturerTeachingRollExportRow>[];
  for (final name in roster) {
    final cells = <String, String>{};
    for (final key in dateKeys) {
      cells[key] = _lecturerCellText(cellMap[name]?[key]);
    }
    rows.add(
      LecturerTeachingRollExportRow(
        lecturerName: name,
        classCount: _totalClassesFor(name, cellMap),
        cellsByDateKey: cells,
      ),
    );
  }

  return LecturerTeachingRollExportData(
    periodLabel: filter.describeRange(anchor),
    dateKeys: dateKeys,
    rows: rows,
  );
}

Future<String?> exportLecturerTeachingRollPdf({
  required LessonPeriodFilter filter,
  required DateTime anchor,
}) async {
  final data = await loadLecturerTeachingRollExport(
    filter: filter,
    anchor: anchor,
  );
  final headerCells = [
    'Lecturer',
    'Period totals',
    ...data.dateKeys.map(_fmtDateKey),
  ];
  final bodyRows = data.rows.map((row) {
    return [
      row.lecturerName,
      '${row.classCount} ${row.classCount == 1 ? 'class' : 'classes'} taught',
      ...data.dateKeys.map((k) => row.cellsByDateKey[k] ?? 'No class'),
    ];
  }).toList();

  return saveRollTablePdf(
    filename: 'Lecturer_teaching_${data.periodLabel}',
    title: 'Lecturer teaching roll',
    subtitle: data.periodLabel,
    headerCells: headerCells,
    bodyRows: bodyRows,
  );
}

/// Maps [CampusPresenceLogPeriod] to [LessonPeriodFilter] for shared dialogs.
LessonPeriodFilter lessonFilterFromCampusPeriod(CampusPresenceLogPeriod period) {
  switch (period) {
    case CampusPresenceLogPeriod.day:
      return LessonPeriodFilter.day;
    case CampusPresenceLogPeriod.week:
      return LessonPeriodFilter.week;
    case CampusPresenceLogPeriod.month:
      return LessonPeriodFilter.month;
  }
}

CampusPresenceLogPeriod campusPeriodFromLessonFilter(LessonPeriodFilter filter) {
  switch (filter) {
    case LessonPeriodFilter.day:
      return CampusPresenceLogPeriod.day;
    case LessonPeriodFilter.week:
      return CampusPresenceLogPeriod.week;
    case LessonPeriodFilter.month:
      return CampusPresenceLogPeriod.month;
  }
}

Future<String?> exportLecturerTeachingRollPdfFromCampusPeriod({
  required CampusPresenceLogPeriod period,
  required DateTime anchor,
}) {
  return exportLecturerTeachingRollPdf(
    filter: lessonFilterFromCampusPeriod(period),
    anchor: anchor,
  );
}
