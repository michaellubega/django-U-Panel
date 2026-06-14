import 'attendance_list_hierarchy.dart';
import 'models/attendance_models.dart';

/// Present vs absent roll rows recorded today (local calendar day).
enum TodayRollPresenceFilter {
  present,
  absent;

  String get title => switch (this) {
        TodayRollPresenceFilter.present => 'Present today',
        TodayRollPresenceFilter.absent => 'Absent today',
      };

  String get emptyMessage => switch (this) {
        TodayRollPresenceFilter.present =>
          'No class lists with present check-ins today.',
        TodayRollPresenceFilter.absent =>
          'No class lists with absent roll rows today.',
      };
}

bool isSameLocalCalendarDay(DateTime a, DateTime b) {
  return a.year == b.year && a.month == b.month && a.day == b.day;
}

/// Class list ids with at least one matching roll row today.
Set<String> listIdsForTodayRollFilter(
  TodayRollPresenceFilter filter, {
  String? studentId,
  Iterable<String>? limitToListIds,
}) {
  final now = DateTime.now();
  final limit = limitToListIds?.map((id) => id.trim()).where((id) => id.isNotEmpty).toSet();
  final wantPresent = filter == TodayRollPresenceFilter.present;
  final out = <String>{};

  for (final r in AttendanceStore.attendanceRecords) {
    if (studentId != null && r.studentId != studentId) continue;
    if (r.present != wantPresent) continue;
    if (!isSameLocalCalendarDay(r.timestamp, now)) continue;
    final session = AttendanceStore.sessionById(r.sessionId);
    if (session == null) continue;
    final listId = session.listId.trim();
    if (listId.isEmpty) continue;
    if (limit != null && !limit.contains(listId)) continue;
    out.add(listId);
  }
  return out;
}

/// Lists in [sourceLists] that have a present/absent roll row today.
List<AttendanceList> listsMatchingTodayRollFilter(
  TodayRollPresenceFilter filter, {
  required Iterable<AttendanceList> sourceLists,
  String? studentId,
}) {
  final scoped = filterListsForHierarchy(sourceLists).toList();
  if (scoped.isEmpty) return const [];

  final ids = listIdsForTodayRollFilter(
    filter,
    studentId: studentId,
    limitToListIds: scoped.map((l) => l.id),
  );
  if (ids.isEmpty) return const [];

  return scoped.where((l) => ids.contains(l.id)).toList()
    ..sort(compareAttendanceListsNewestFirst);
}

/// Staff lists or a single student's signed-in lists as the filter source.
List<AttendanceList> sourceListsForTodayRollScope({String? studentId}) {
  if (studentId != null && studentId.trim().isNotEmpty) {
    final sid = studentId.trim();
    final listIds = AttendanceStore.signIns
        .where((s) => s.studentId == sid)
        .map((s) => s.listId)
        .toSet();
    return filterListsForHierarchy(
      AttendanceStore.lists.where((l) => listIds.contains(l.id)),
    ).toList()
      ..sort(compareAttendanceListsNewestFirst);
  }
  return attendanceListsForCurrentStaff();
}

List<AttendanceList> scopedListsForTodayRollFilter({
  required TodayRollPresenceFilter filter,
  String? studentId,
}) {
  return listsMatchingTodayRollFilter(
    filter,
    sourceLists: sourceListsForTodayRollScope(studentId: studentId),
    studentId: studentId,
  );
}

int todayRollCountForFilter(
  TodayRollPresenceFilter filter, {
  String? studentId,
}) {
  final now = DateTime.now();
  final wantPresent = filter == TodayRollPresenceFilter.present;
  Iterable<String> sessionIds;
  if (studentId != null) {
    final signedListIds = AttendanceStore.signIns
        .where((s) => s.studentId == studentId)
        .map((s) => s.listId)
        .toSet();
    sessionIds = AttendanceStore.sessions
        .where((s) => signedListIds.contains(s.listId))
        .map((s) => s.id);
  } else {
    final listIds = attendanceListsForCurrentStaff().map((l) => l.id).toSet();
    sessionIds = AttendanceStore.sessions
        .where((s) => listIds.contains(s.listId))
        .map((s) => s.id);
  }
  final sessionIdSet = sessionIds.toSet();
  var count = 0;
  for (final r in AttendanceStore.attendanceRecords) {
    if (studentId != null && r.studentId != studentId) continue;
    if (!sessionIdSet.contains(r.sessionId)) continue;
    if (!isSameLocalCalendarDay(r.timestamp, now)) continue;
    if (r.present == wantPresent) count++;
  }
  return count;
}
