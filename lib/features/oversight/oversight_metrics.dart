import '../attendance/attendance_list_hierarchy.dart';
import '../attendance/models/attendance_models.dart';

/// Default exam bar used by KIU-QAAT (75%).
const kOversightEligibilityFloor = 75.0;

class OversightGhostSession {
  const OversightGhostSession({
    required this.listId,
    required this.unitName,
    required this.dateLabel,
    required this.studentCount,
  });

  final String listId;
  final String unitName;
  final String dateLabel;
  final int studentCount;
}

class OversightLecturerRow {
  const OversightLecturerRow({
    required this.name,
    required this.sessionCount,
    required this.present,
    required this.enrolled,
  });

  final String name;
  final int sessionCount;
  final int present;
  final int enrolled;

  double get turnoutPct => enrolled == 0 ? 0 : (present / enrolled) * 100;
}

class OversightStudentRow {
  const OversightStudentRow({
    required this.studentId,
    required this.name,
    required this.present,
    required this.possible,
  });

  final String studentId;
  final String name;
  final int present;
  final int possible;

  double get pct => possible == 0 ? 0 : (present / possible) * 100;
}

class OversightSnapshot {
  const OversightSnapshot({
    required this.scheduledSessions,
    required this.actualSessions,
    required this.studentsPresent,
    required this.avgAttendancePct,
    required this.ier,
    required this.eligible,
    required this.ineligible,
    required this.pending,
    required this.ghostSessions,
    required this.lecturers,
    required this.atRisk,
  });

  final int scheduledSessions;
  final int actualSessions;
  final int studentsPresent;
  final double avgAttendancePct;
  final double ier;
  final int eligible;
  final int ineligible;
  final int pending;
  final List<OversightGhostSession> ghostSessions;
  final List<OversightLecturerRow> lecturers;
  final List<OversightStudentRow> atRisk;

  int get ghostLectureCount => ghostSessions.length;

  static OversightSnapshot empty() => const OversightSnapshot(
        scheduledSessions: 0,
        actualSessions: 0,
        studentsPresent: 0,
        avgAttendancePct: 0,
        ier: 0,
        eligible: 0,
        ineligible: 0,
        pending: 0,
        ghostSessions: [],
        lecturers: [],
        atRisk: [],
      );
}

/// Reads existing [AttendanceStore] data. Does not write sessions or records.
abstract final class OversightMetrics {
  static OversightSnapshot compute({
    DateTime? now,
    AttendanceProgram? program,
    String? year,
  }) {
    final today = (now ?? DateTime.now()).toLocal();
    final weekday = today.weekday.clamp(1, 7);
    var lists = filterListsForHierarchy(AttendanceStore.lists);
    if (program != null) {
      lists = lists.where((l) => l.program == program).toList();
    }
    if (year != null && year.trim().isNotEmpty) {
      final y = year.trim();
      lists = lists.where((l) => l.year.trim() == y).toList();
    }

    final scheduled = lists.where((l) => l.date.weekday == weekday).toList();
    final scheduledIds = scheduled.map((l) => l.id).toSet();

    bool sessionOnDay(AttendanceSession s) {
      final started = s.startTime.toLocal();
      return started.year == today.year &&
          started.month == today.month &&
          started.day == today.day;
    }

    final actual = AttendanceStore.sessions.where((s) {
      if (!scheduledIds.contains(s.listId) &&
          !lists.any((l) => l.id == s.listId)) {
        return false;
      }
      return sessionOnDay(s);
    }).toList();

    final actualListIds = actual.map((s) => s.listId).toSet();

    var presentToday = 0;
    var enrolledToday = 0;
    for (final session in actual) {
      final enrolled = AttendanceStore.studentIdsSignedIntoList(session.listId);
      enrolledToday += enrolled.length;
      for (final sid in enrolled) {
        if (AttendanceStore.isPresentForSession(session.id, sid)) {
          presentToday++;
        }
      }
    }

    final avg = enrolledToday == 0 ? 0.0 : (presentToday / enrolledToday) * 100;
    final scheduledCount = scheduled.length;
    final actualCount = actual.length;
    final coverage = scheduledCount == 0 ? 0.0 : actualCount / scheduledCount;
    final ier = coverage * avg;

    final ghosts = <OversightGhostSession>[];
    for (final list in scheduled) {
      if (actualListIds.contains(list.id)) continue;
      final enrolled = AttendanceStore.studentIdsSignedIntoList(list.id);
      ghosts.add(
        OversightGhostSession(
          listId: list.id,
          unitName: list.courses?.isNotEmpty == true
              ? list.courses!.join(', ')
              : (list.whoTaught.trim().isEmpty ? 'Untitled list' : list.whoTaught),
          dateLabel: kAttendanceWeekdayFullNames[weekday - 1],
          studentCount: enrolled.length,
        ),
      );
    }

    final lecturerMap = <String, OversightLecturerRow>{};
    for (final session in actual) {
      final list = AttendanceStore.listById(session.listId);
      if (list == null) continue;
      final name = list.whoTaught.trim().isEmpty ? 'Unknown' : list.whoTaught.trim();
      final enrolled = AttendanceStore.studentIdsSignedIntoList(list.id);
      var present = 0;
      for (final sid in enrolled) {
        if (AttendanceStore.isPresentForSession(session.id, sid)) present++;
      }
      final prev = lecturerMap[name];
      lecturerMap[name] = OversightLecturerRow(
        name: name,
        sessionCount: (prev?.sessionCount ?? 0) + 1,
        present: (prev?.present ?? 0) + present,
        enrolled: (prev?.enrolled ?? 0) + enrolled.length,
      );
    }

    final possibleByStudent = <String, int>{};
    final presentByStudent = <String, int>{};
    for (final session in AttendanceStore.sessions) {
      if (!lists.any((l) => l.id == session.listId)) continue;
      final enrolled = AttendanceStore.studentIdsSignedIntoList(session.listId);
      for (final sid in enrolled) {
        possibleByStudent[sid] = (possibleByStudent[sid] ?? 0) + 1;
        if (AttendanceStore.isPresentForSession(session.id, sid)) {
          presentByStudent[sid] = (presentByStudent[sid] ?? 0) + 1;
        }
      }
    }

    var eligible = 0;
    var ineligible = 0;
    var pending = 0;
    final atRisk = <OversightStudentRow>[];
    for (final entry in possibleByStudent.entries) {
      final sid = entry.key;
      final possible = entry.value;
      final present = presentByStudent[sid] ?? 0;
      if (possible < 3) {
        pending++;
        continue;
      }
      final pct = possible == 0 ? 0.0 : (present / possible) * 100;
      if (pct >= kOversightEligibilityFloor) {
        eligible++;
      } else {
        ineligible++;
        StudentRecord? student;
        for (final row in AttendanceStore.students) {
          if (row.id == sid || row.registrationNumber == sid) {
            student = row;
            break;
          }
        }
        atRisk.add(
          OversightStudentRow(
            studentId: sid,
            name: student != null && student.name.trim().isNotEmpty
                ? student.name
                : sid,
            present: present,
            possible: possible,
          ),
        );
      }
    }
    atRisk.sort((a, b) => a.pct.compareTo(b.pct));

    final lecturers = lecturerMap.values.toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    return OversightSnapshot(
      scheduledSessions: scheduledCount,
      actualSessions: actualCount,
      studentsPresent: presentToday,
      avgAttendancePct: avg,
      ier: ier,
      eligible: eligible,
      ineligible: ineligible,
      pending: pending,
      ghostSessions: ghosts,
      lecturers: lecturers,
      atRisk: atRisk.take(40).toList(),
    );
  }
}
