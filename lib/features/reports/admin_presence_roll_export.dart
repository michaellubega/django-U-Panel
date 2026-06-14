import '../campus_presence/campus_presence_grouping.dart';
import '../campus_presence/campus_presence_policy.dart';
import '../campus_presence/data/campus_presence_repository.dart';
import '../campus_presence/models/campus_presence_models.dart';
import 'reports_roll_pdf.dart';

class AdminPresencePeriodStats {
  const AdminPresencePeriodStats({
    required this.totalOverwork,
    required this.totalLate,
    required this.daysPresent,
    required this.weekdaysAbsent,
  });

  final Duration totalOverwork;
  final Duration totalLate;
  final int daysPresent;
  final int weekdaysAbsent;

  String get summaryText => [
        'Overwork ${CampusPresencePolicy.formatDuration(totalOverwork)}',
        'Late ${CampusPresencePolicy.formatDuration(totalLate)}',
        'Present $daysPresent days',
        'Absent $weekdaysAbsent weekdays',
      ].join('\n');
}

class AdminPresenceRollExportRow {
  const AdminPresenceRollExportRow({
    required this.admin,
    required this.stats,
    required this.cellsByDateKey,
  });

  final AdminCampusRosterEntry admin;
  final AdminPresencePeriodStats stats;
  final Map<String, String> cellsByDateKey;
}

class AdminPresenceRollExportData {
  const AdminPresenceRollExportData({
    required this.periodLabel,
    required this.dateKeys,
    required this.rows,
  });

  final String periodLabel;
  final List<String> dateKeys;
  final List<AdminPresenceRollExportRow> rows;
}

bool _isWeekday(DateTime day) =>
    day.weekday != DateTime.saturday && day.weekday != DateTime.sunday;

List<String> _dateKeysRecentFirst(
  CampusPresenceLogPeriod period,
  DateTime anchor,
) {
  final range = localDateRangeForPeriod(period, anchor);
  final keys = <String>[];
  var day = range.start;
  while (!day.isAfter(range.end)) {
    keys.add(localDateKeyFor(day));
    day = day.add(const Duration(days: 1));
  }
  return keys.reversed.toList();
}

AdminPresencePeriodStats _periodStatsFor(
  String adminUid,
  List<String> dateKeys,
  Map<String, Map<String, StaffDayPresenceRow>> cellMap,
) {
  final byDate = cellMap[adminUid] ?? {};
  var overwork = Duration.zero;
  var late = Duration.zero;
  var daysPresent = 0;
  var weekdaysAbsent = 0;

  for (final key in dateKeys) {
    final date = CampusPresencePolicy.dateFromLocalDateKey(key);
    if (date == null) continue;
    final row = byDate[key];
    if (row != null && row.hasCheckIn) {
      daysPresent++;
      final arrival = row.arrival?.capturedAt;
      if (arrival != null) {
        final lateness = CampusPresencePolicy.latenessAfterThreshold(arrival);
        if (lateness != null) late += lateness;
      }
      final departure = row.departure?.capturedAt;
      if (departure != null) {
        final over = CampusPresencePolicy.overworkAfterThreshold(departure);
        if (over != null) overwork += over;
      }
    } else if (_isWeekday(date)) {
      weekdaysAbsent++;
    }
  }

  return AdminPresencePeriodStats(
    totalOverwork: overwork,
    totalLate: late,
    daysPresent: daysPresent,
    weekdaysAbsent: weekdaysAbsent,
  );
}

String? _latestPresenceKey(
  String adminUid,
  Map<String, Map<String, StaffDayPresenceRow>> cellMap,
) {
  final byDate = cellMap[adminUid];
  if (byDate == null || byDate.isEmpty) return null;
  final keys = byDate.entries
      .where((e) => e.value.hasCheckIn)
      .map((e) => e.key)
      .toList()
    ..sort((a, b) => b.compareTo(a));
  return keys.isEmpty ? null : keys.first;
}

String _formatTime(DateTime? t) {
  if (t == null) return '—';
  return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
}

String _adminCellText(StaffDayPresenceRow? row) {
  if (row == null || !row.hasCheckIn) return 'Absent';
  final flags = row.flags();
  final parts = <String>[
    'In ${_formatTime(row.arrival?.capturedAt)}',
    'Out ${_formatTime(row.departure?.capturedAt)}',
  ];
  if (flags.lateArrival) {
    parts.add(flags.arrivalStatusNote ?? 'Late');
  }
  if (flags.overwork) {
    parts.add(
      flags.departureStatusNotes
              .where((n) => n.startsWith('Overwork'))
              .firstOrNull ??
          'Overwork',
    );
  } else if (flags.earlyDeparture) {
    parts.add(
      flags.departureStatusNotes
              .where((n) => n.startsWith('Left early'))
              .firstOrNull ??
          'Left early',
    );
  }
  if (row.arrival != null) parts.add(flags.hoursLabel);
  return parts.join('\n');
}

String _fmtDateKey(String key) {
  final d = CampusPresencePolicy.dateFromLocalDateKey(key);
  if (d == null) return key;
  return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}';
}

String _periodTitle(CampusPresenceLogPeriod period, DateTime anchor) {
  final range = localDateRangeForPeriod(period, anchor);
  String fmt(DateTime d) =>
      '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  switch (period) {
    case CampusPresenceLogPeriod.day:
      return fmt(anchor);
    case CampusPresenceLogPeriod.week:
      return '${fmt(range.start)} – ${fmt(range.end)}';
    case CampusPresenceLogPeriod.month:
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
      return '${names[anchor.month - 1]} ${anchor.year}';
  }
}

Future<AdminPresenceRollExportData> loadAdminPresenceRollExport({
  required CampusPresenceLogPeriod period,
  required DateTime anchor,
}) async {
  final range = localDateRangeForPeriod(period, anchor);
  final repo = CampusPresenceRepository.instance;
  final roster = await repo.fetchKiuAdminRoster();
  final events = await repo.fetchEventsInLocalDateRange(
    rangeStart: range.start,
    rangeEnd: range.end,
  );

  final grouped = groupEventsIntoDayRows(events);
  final cellMap = <String, Map<String, StaffDayPresenceRow>>{};
  for (final row in grouped) {
    (cellMap[row.adminUid] ??= {})[row.localDateKey] = row;
  }

  final dateKeys = _dateKeysRecentFirst(period, anchor);
  final sorted = [...roster]
    ..sort((a, b) {
      final latestA = _latestPresenceKey(a.uid, cellMap);
      final latestB = _latestPresenceKey(b.uid, cellMap);
      if (latestA != null && latestB != null) {
        final byDate = latestB.compareTo(latestA);
        if (byDate != 0) return byDate;
      } else if (latestA != null) {
        return -1;
      } else if (latestB != null) {
        return 1;
      }
      return a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
    });

  final rows = <AdminPresenceRollExportRow>[];
  for (final admin in sorted) {
    final stats = _periodStatsFor(admin.uid, dateKeys, cellMap);
    final cells = <String, String>{};
    for (final key in dateKeys) {
      cells[key] = _adminCellText(cellMap[admin.uid]?[key]);
    }
    rows.add(
      AdminPresenceRollExportRow(
        admin: admin,
        stats: stats,
        cellsByDateKey: cells,
      ),
    );
  }

  return AdminPresenceRollExportData(
    periodLabel: _periodTitle(period, anchor),
    dateKeys: dateKeys,
    rows: rows,
  );
}

Future<String?> exportAdminPresenceRollPdf({
  required CampusPresenceLogPeriod period,
  required DateTime anchor,
}) async {
  final data = await loadAdminPresenceRollExport(
    period: period,
    anchor: anchor,
  );
  final headerCells = [
    'Administrator',
    'Period totals',
    ...data.dateKeys.map(_fmtDateKey),
  ];
  final bodyRows = data.rows.map((row) {
    final nameParts = <String>[row.admin.displayName];
    if (row.admin.staffNumber?.isNotEmpty == true) {
      nameParts.add(row.admin.staffNumber!);
    }
    if (row.admin.jobTitle?.isNotEmpty == true) {
      nameParts.add(row.admin.jobTitle!);
    }
    return [
      nameParts.join('\n'),
      row.stats.summaryText,
      ...data.dateKeys.map((k) => row.cellsByDateKey[k] ?? 'Absent'),
    ];
  }).toList();

  return saveRollTablePdf(
    filename: 'KIU_admin_presence_${data.periodLabel}',
    title: 'KIU admin presence roll',
    subtitle: data.periodLabel,
    headerCells: headerCells,
    bodyRows: bodyRows,
  );
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull {
    final it = iterator;
    if (!it.moveNext()) return null;
    return it.current;
  }
}
