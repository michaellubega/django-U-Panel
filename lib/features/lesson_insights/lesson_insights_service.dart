import '../../core/auth/auth_repository.dart';
import '../attendance/attendance_list_hierarchy.dart';
import '../attendance/models/attendance_models.dart';
import '../attendance/roll_cell_status.dart';
import 'lesson_insights_models.dart';
import 'lesson_period_filter.dart';

/// Computes lesson / session insights from [AttendanceStore].
class LessonInsightsService {
  LessonInsightsService._();

  static String normalizeLecturerName(String raw) =>
      raw.trim().replaceAll(RegExp(r'\s+'), ' ');

  static String lecturerNameForList(AttendanceList list) =>
      normalizeLecturerName(list.whoTaught);

  static bool listHasOnboardedStudents(String listId) =>
      AttendanceStore.studentIdsSignedIntoList(listId).isNotEmpty;

  static bool sessionQualifies(AttendanceSession session) {
    final list = AttendanceStore.listById(session.listId);
    if (list == null) return false;
    if (!attendanceListVisibleInHierarchy(list)) return false;
    return listHasOnboardedStudents(list.id);
  }

  static bool listBelongsToCurrentLecturer(AttendanceList list) {
    final auth = AuthRepository.instance;
    if (!auth.lecturerCheckDone || !auth.isLecturer || auth.isAdmin) {
      return false;
    }
    final uid = auth.currentFirebaseUid?.trim();
    if (uid != null &&
        uid.isNotEmpty &&
        attendanceListAccessibleToLecturer(list, uid)) {
      return true;
    }
    final name = auth.currentFullName?.trim().toLowerCase();
    if (name != null && name.isNotEmpty) {
      return list.whoTaught.trim().toLowerCase() == name;
    }
    return false;
  }

  static LessonSessionRollCounts rollCountsForSession(
    AttendanceSession session,
    AttendanceList list,
    RollPendingContext pending, {
    DateTime? now,
  }) {
    if (!session.isActive) {
      final rtd = AttendanceStore.sessionRollStats(session.id);
      if (rtd != null) {
        return LessonSessionRollCounts(
          enrolled: rtd.enrolled,
          present: rtd.present,
          absent: rtd.absent,
          pending: rtd.pending,
        );
      }
    }

    final studentIds = AttendanceStore.studentIdsSignedIntoList(list.id);
    if (studentIds.isEmpty) return LessonSessionRollCounts.empty;

    var present = 0;
    var absent = 0;
    var pendingCount = 0;

    for (final sid in studentIds) {
      final records = AttendanceStore.attendanceRecords
          .where((r) => r.studentId == sid)
          .toList();
      final label = rollCellLabelForStudentSession(
        session: session,
        studentId: sid,
        recordsForStudent: records,
        pending: pending,
        now: now,
      );
      switch (label) {
        case kRollLabelPresent:
          present++;
          break;
        case kRollLabelAbsent:
          absent++;
          break;
        case kRollLabelPending:
          pendingCount++;
          break;
        default:
          break;
      }
    }

    return LessonSessionRollCounts(
      enrolled: studentIds.length,
      present: present,
      absent: absent,
      pending: pendingCount,
    );
  }

  static LessonSessionInsight? insightForSession(
    AttendanceSession session,
    RollPendingContext pending, {
    DateTime? now,
  }) {
    if (!sessionQualifies(session)) return null;
    final list = AttendanceStore.listById(session.listId);
    if (list == null) return null;
    return LessonSessionInsight(
      session: session,
      list: list,
      lecturerName: lecturerNameForList(list),
      roll: rollCountsForSession(session, list, pending, now: now),
    );
  }

  static List<LessonSessionInsight> allQualifyingInsights(
    RollPendingContext pending, {
    DateTime? now,
    bool lecturerScopeOnly = false,
  }) {
    final out = <LessonSessionInsight>[];
    for (final session in AttendanceStore.sessions) {
      final insight = insightForSession(session, pending, now: now);
      if (insight == null) continue;
      if (lecturerScopeOnly &&
          !listBelongsToCurrentLecturer(insight.list)) {
        continue;
      }
      out.add(insight);
    }
    out.sort(
      (a, b) => b.session.startTime.compareTo(a.session.startTime),
    );
    return out;
  }

  static List<LessonSessionInsight> insightsInPeriod(
    RollPendingContext pending, {
    required LessonPeriodFilter filter,
    required DateTime anchor,
    bool lecturerScopeOnly = false,
    DateTime? now,
  }) {
    return allQualifyingInsights(
      pending,
      now: now,
      lecturerScopeOnly: lecturerScopeOnly,
    ).where(
      (i) => filter.containsSessionStartOn(i.session.startTime, anchor),
    ).toList();
  }

  static List<LessonSessionInsight> insightsOnDay(
    RollPendingContext pending, {
    required DateTime day,
    bool lecturerScopeOnly = false,
    DateTime? now,
  }) {
    return insightsInPeriod(
      pending,
      filter: LessonPeriodFilter.day,
      anchor: day,
      lecturerScopeOnly: lecturerScopeOnly,
      now: now,
    );
  }

  static List<LecturerLessonAggregate> lecturerAggregates(
    List<LessonSessionInsight> insights,
  ) {
    final byName = <String, List<LessonSessionInsight>>{};
    for (final i in insights) {
      final key = lecturerNameForList(i.list);
      if (key.isEmpty) continue;
      (byName[key] ??= []).add(i);
    }

    final out = <LecturerLessonAggregate>[];
    for (final entry in byName.entries) {
      final classes = entry.value.map((i) => i.list.id).toSet();
      var present = 0;
      var absent = 0;
      var pending = 0;
      var enrolled = 0;
      for (final i in entry.value) {
        present += i.roll.present;
        absent += i.roll.absent;
        pending += i.roll.pending;
        enrolled += i.roll.enrolled;
      }
      out.add(
        LecturerLessonAggregate(
          lecturerName: entry.key,
          sessionCount: entry.value.length,
          classCount: classes.length,
          totalPresent: present,
          totalAbsent: absent,
          totalPending: pending,
          totalEnrolled: enrolled,
        ),
      );
    }
    out.sort((a, b) {
      final bySessions = b.sessionCount.compareTo(a.sessionCount);
      if (bySessions != 0) return bySessions;
      return a.lecturerName.toLowerCase().compareTo(b.lecturerName.toLowerCase());
    });
    return out;
  }

  static List<LessonsPerDayBucket> lessonsPerDayBuckets(
    List<LessonSessionInsight> insights,
    LessonPeriodFilter filter,
    DateTime anchor,
  ) {
    final (start, end) = filter.dateRange(anchor);
    final map = <DateTime, List<LessonSessionInsight>>{};
    for (final i in insights) {
      final d = i.lessonDate;
      if (d.isBefore(start) || d.isAfter(end)) continue;
      (map[d] ??= []).add(i);
    }

    final days = <DateTime>[];
    var cursor = start;
    while (!cursor.isAfter(end)) {
      days.add(cursor);
      cursor = cursor.add(const Duration(days: 1));
    }

    return [
      for (final d in days)
        LessonsPerDayBucket(
          date: d,
          sessionCount: map[d]?.length ?? 0,
          lecturerNames: [
            ...{
              for (final i in map[d] ?? const <LessonSessionInsight>[])
                i.lecturerName,
            },
          ]..sort(),
        ),
    ];
  }

  static Map<String, List<LessonSessionInsight>> groupByList(
    List<LessonSessionInsight> insights,
  ) {
    final map = <String, List<LessonSessionInsight>>{};
    for (final i in insights) {
      (map[i.list.id] ??= []).add(i);
    }
    for (final list in map.values) {
      list.sort((a, b) => b.session.startTime.compareTo(a.session.startTime));
    }
    return map;
  }
}
