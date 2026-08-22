import '../attendance/models/attendance_models.dart';

/// Roll counts for one taught session (class with onboarded students).
class LessonSessionRollCounts {
  const LessonSessionRollCounts({
    required this.enrolled,
    required this.present,
    required this.absent,
    required this.pending,
  });

  final int enrolled;
  final int present;
  final int absent;
  final int pending;

  static const empty = LessonSessionRollCounts(
    enrolled: 0,
    present: 0,
    absent: 0,
    pending: 0,
  );
}

/// One qualifying session with list context and attendance breakdown.
class LessonSessionInsight {
  const LessonSessionInsight({
    required this.session,
    required this.list,
    required this.lecturerName,
    required this.roll,
  });

  final AttendanceSession session;
  final AttendanceList list;
  final String lecturerName;
  final LessonSessionRollCounts roll;

  DateTime get lessonDate => DateTime(
        session.startTime.year,
        session.startTime.month,
        session.startTime.day,
      );

  String get courseLabel => list.effectiveCourseUnitName.isNotEmpty
      ? list.effectiveCourseUnitName
      : list.courseSummaryLine;

  String get yearSemLabel => '${list.yearLabel} · Sem ${list.sem}';
}

/// Aggregated lesson count for one lecturer in a period.
class LecturerLessonAggregate {
  const LecturerLessonAggregate({
    required this.lecturerName,
    required this.sessionCount,
    required this.classCount,
    required this.totalPresent,
    required this.totalAbsent,
    required this.totalPending,
    required this.totalEnrolled,
  });

  final String lecturerName;
  final int sessionCount;
  final int classCount;
  final int totalPresent;
  final int totalAbsent;
  final int totalPending;
  final int totalEnrolled;
}

/// Lessons grouped by calendar day (for charts / summaries).
class LessonsPerDayBucket {
  const LessonsPerDayBucket({
    required this.date,
    required this.sessionCount,
    required this.lecturerNames,
  });

  final DateTime date;
  final int sessionCount;
  final List<String> lecturerNames;
}
