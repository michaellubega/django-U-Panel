import 'models/campus_presence_models.dart';

/// One staff member's arrival + departure on a single local day.
class StaffDayPresenceRow {
  const StaffDayPresenceRow({
    required this.adminUid,
    required this.displayName,
    this.staffNumber,
    this.jobTitle,
    required this.localDateKey,
    this.arrival,
    this.departure,
  });

  final String adminUid;
  final String displayName;
  final String? staffNumber;
  final String? jobTitle;
  final String localDateKey;
  final CampusPresenceEvent? arrival;
  final CampusPresenceEvent? departure;

  bool get hasCheckIn => arrival != null;

  String get subtitle {
    final parts = <String>[];
    if (arrival != null) {
      parts.add('In ${_formatTime(arrival!.capturedAt)}');
    }
    if (departure != null) {
      parts.add('Out ${_formatTime(departure!.capturedAt)}');
    }
    if (parts.isEmpty) return 'No events';
    return parts.join(' · ');
  }

  static String _formatTime(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }
}

/// Check-in totals for one staff member over a date range.
class StaffPresencePeriodSummary {
  const StaffPresencePeriodSummary({
    required this.adminUid,
    required this.displayName,
    this.staffNumber,
    this.jobTitle,
    required this.checkInCount,
    required this.dayRows,
  });

  final String adminUid;
  final String displayName;
  final String? staffNumber;
  final String? jobTitle;
  /// Days with at least one arrival (max one per day).
  final int checkInCount;
  final List<StaffDayPresenceRow> dayRows;
}

enum CampusPresenceLogPeriod {
  day,
  week,
  month,
}

extension CampusPresenceLogPeriodX on CampusPresenceLogPeriod {
  String get label {
    switch (this) {
      case CampusPresenceLogPeriod.day:
        return 'Day';
      case CampusPresenceLogPeriod.week:
        return 'Week';
      case CampusPresenceLogPeriod.month:
        return 'Month';
    }
  }
}

/// Inclusive local-date range `[start, end]` (both at midnight local).
({DateTime start, DateTime end}) localDateRangeForPeriod(
  CampusPresenceLogPeriod period,
  DateTime anchor,
) {
  final day = DateTime(anchor.year, anchor.month, anchor.day);
  switch (period) {
    case CampusPresenceLogPeriod.day:
      return (start: day, end: day);
    case CampusPresenceLogPeriod.week:
      final start = day.subtract(Duration(days: day.weekday - DateTime.monday));
      return (start: start, end: start.add(const Duration(days: 6)));
    case CampusPresenceLogPeriod.month:
      final start = DateTime(day.year, day.month, 1);
      final end = DateTime(day.year, day.month + 1, 0);
      return (start: start, end: end);
  }
}

String campusPresenceDocId({
  required String adminUid,
  required String localDateKey,
  required CampusPresenceKind kind,
}) =>
    '${adminUid}_${localDateKey}_${kind.firestoreValue}';

List<StaffDayPresenceRow> groupEventsIntoDayRows(
  List<CampusPresenceEvent> events,
) {
  final map = <String, Map<String, StaffDayPresenceRowBuilder>>{};
  for (final e in events) {
    final byDay = map.putIfAbsent(e.adminUid, () => {});
    final builder = byDay.putIfAbsent(
      e.localDateKey,
      () => StaffDayPresenceRowBuilder(
        adminUid: e.adminUid,
        localDateKey: e.localDateKey,
        displayName: _displayNameForEvent(e),
        staffNumber: e.staffNumber,
        jobTitle: e.jobTitle,
      ),
    );
    builder.mergeEvent(e);
  }

  final rows = <StaffDayPresenceRow>[];
  for (final byDay in map.values) {
    rows.addAll(byDay.values.map((b) => b.build()));
  }
  rows.sort((a, b) {
    final c = b.localDateKey.compareTo(a.localDateKey);
    if (c != 0) return c;
    return a.displayName.compareTo(b.displayName);
  });
  return rows;
}

List<StaffPresencePeriodSummary> summarizeCheckInsByStaff(
  List<CampusPresenceEvent> events,
) {
  final dayRows = groupEventsIntoDayRows(events);
  final byStaff = <String, List<StaffDayPresenceRow>>{};
  for (final row in dayRows) {
    byStaff.putIfAbsent(row.adminUid, () => []).add(row);
  }

  final summaries = <StaffPresencePeriodSummary>[];
  for (final entry in byStaff.entries) {
    final rows = entry.value
      ..sort((a, b) => b.localDateKey.compareTo(a.localDateKey));
    final first = rows.first;
    summaries.add(
      StaffPresencePeriodSummary(
        adminUid: entry.key,
        displayName: first.displayName,
        staffNumber: first.staffNumber,
        jobTitle: first.jobTitle,
        checkInCount: rows.where((r) => r.hasCheckIn).length,
        dayRows: rows,
      ),
    );
  }
  summaries.sort((a, b) {
    final c = b.checkInCount.compareTo(a.checkInCount);
    if (c != 0) return c;
    return a.displayName.compareTo(b.displayName);
  });
  return summaries;
}

List<StaffDayPresenceRow> dayRowsForSingleLocalDate(
  List<CampusPresenceEvent> events,
  String localDateKey,
) {
  return groupEventsIntoDayRows(events)
      .where((r) => r.localDateKey == localDateKey)
      .toList()
    ..sort((a, b) => a.displayName.compareTo(b.displayName));
}

String _displayNameForEvent(CampusPresenceEvent e) {
  if (e.displayName?.trim().isNotEmpty == true) return e.displayName!.trim();
  if (e.staffNumber?.trim().isNotEmpty == true) return e.staffNumber!.trim();
  if (e.adminEmail?.trim().isNotEmpty == true) return e.adminEmail!.trim();
  return e.adminUid;
}

class StaffDayPresenceRowBuilder {
  StaffDayPresenceRowBuilder({
    required this.adminUid,
    required this.localDateKey,
    required this.displayName,
    this.staffNumber,
    this.jobTitle,
  });

  final String adminUid;
  final String localDateKey;
  String displayName;
  String? staffNumber;
  String? jobTitle;
  CampusPresenceEvent? arrival;
  CampusPresenceEvent? departure;

  void mergeEvent(CampusPresenceEvent e) {
    if (e.displayName?.trim().isNotEmpty == true) {
      displayName = e.displayName!.trim();
    }
    if (e.staffNumber?.trim().isNotEmpty == true) {
      staffNumber = e.staffNumber!.trim();
    }
    if (e.jobTitle?.trim().isNotEmpty == true) {
      jobTitle = e.jobTitle!.trim();
    }
    switch (e.kind) {
      case CampusPresenceKind.arrival:
        arrival ??= e;
        break;
      case CampusPresenceKind.departure:
        departure ??= e;
        break;
    }
  }

  StaffDayPresenceRow build() => StaffDayPresenceRow(
        adminUid: adminUid,
        displayName: displayName,
        staffNumber: staffNumber,
        jobTitle: jobTitle,
        localDateKey: localDateKey,
        arrival: arrival,
        departure: departure,
      );
}
