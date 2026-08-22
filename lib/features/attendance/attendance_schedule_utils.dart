import 'models/attendance_models.dart';

/// Campus timetable helpers — list [AttendanceList.time] is HH:mm (24h) and
/// [AttendanceList.date] is weekday-only (Mon…Sun).
class AttendanceScheduleUtils {
  AttendanceScheduleUtils._();

  /// QA is notified when a lecturer still has not opened a session this long
  /// after the scheduled lesson time (1 hour 30 minutes).
  static const Duration qaEscalationAfter = Duration(hours: 1, minutes: 30);

  static int? parseListTimeMinutes(String raw) {
    final t = raw.trim();
    final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(t);
    if (m == null) return null;
    final h = int.tryParse(m.group(1)!);
    final min = int.tryParse(m.group(2)!);
    if (h == null || min == null) return null;
    if (h < 0 || h > 23 || min < 0 || min > 59) return null;
    return h * 60 + min;
  }

  static bool isListScheduledOnDate(AttendanceList list, DateTime day) {
    return list.date.weekday == day.weekday;
  }

  static DateTime? scheduledStartOnDate(AttendanceList list, DateTime day) {
    final mins = parseListTimeMinutes(list.time);
    if (mins == null) return null;
    return DateTime(
      day.year,
      day.month,
      day.day,
      mins ~/ 60,
      mins % 60,
    );
  }

  static bool listHasSessionOnLocalDay(String listId, DateTime day) {
    for (final s in AttendanceStore.sessions) {
      if (s.listId != listId) continue;
      final st = s.startTime.toLocal();
      if (st.year == day.year && st.month == day.month && st.day == day.day) {
        return true;
      }
    }
    return false;
  }

  static bool isDueForLecturerReminder(AttendanceList list, DateTime now) {
    if (list.status == AttendanceListStatus.closed) return false;
    if (!isListScheduledOnDate(list, now)) return false;
    if (listHasSessionOnLocalDay(list.id, now)) return false;
    final scheduled = scheduledStartOnDate(list, now);
    if (scheduled == null) return false;
    return !now.isBefore(scheduled);
  }

  static bool isOverdueForQa(AttendanceList list, DateTime now) {
    if (list.status == AttendanceListStatus.closed) return false;
    if (!isListScheduledOnDate(list, now)) return false;
    if (listHasSessionOnLocalDay(list.id, now)) return false;
    final scheduled = scheduledStartOnDate(list, now);
    if (scheduled == null) return false;
    final qaDue = scheduled.add(qaEscalationAfter);
    return !now.isBefore(qaDue);
  }

  /// Lists that QA should act on today (no session yet, 1:30 past scheduled time).
  static List<AttendanceList> overdueListsForQa({
    Iterable<AttendanceList>? lists,
    DateTime? now,
  }) {
    final clock = (now ?? DateTime.now()).toLocal();
    final source = lists ?? AttendanceStore.lists;
    final out = <AttendanceList>[];
    for (final list in source) {
      if (isOverdueForQa(list, clock)) out.add(list);
    }
    out.sort((a, b) {
      final sa = scheduledStartOnDate(a, clock);
      final sb = scheduledStartOnDate(b, clock);
      if (sa == null && sb == null) return a.displayTitle.compareTo(b.displayTitle);
      if (sa == null) return 1;
      if (sb == null) return -1;
      return sa.compareTo(sb);
    });
    return out;
  }

  /// Lists assigned to the current lecturer that are due now (scheduled time passed).
  static List<AttendanceList> dueListsForLecturer(
    Iterable<AttendanceList> lists, {
    DateTime? now,
  }) {
    final clock = (now ?? DateTime.now()).toLocal();
    final out = <AttendanceList>[];
    for (final list in lists) {
      if (isDueForLecturerReminder(list, clock)) out.add(list);
    }
    out.sort((a, b) {
      final sa = scheduledStartOnDate(a, clock);
      final sb = scheduledStartOnDate(b, clock);
      if (sa == null && sb == null) return a.displayTitle.compareTo(b.displayTitle);
      if (sa == null) return 1;
      if (sb == null) return -1;
      return sa.compareTo(sb);
    });
    return out;
  }
}
