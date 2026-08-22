import '../attendance/models/attendance_models.dart';
import '../attendance/roll_cell_status.dart';

export '../attendance/attendance_list_hierarchy.dart' show attendanceListsForCurrentStaff;

/// One student row in a consolidated class-list roll.
class AttendanceListRollStudentRow {
  const AttendanceListRollStudentRow({
    required this.studentId,
    required this.name,
    required this.registrationNumber,
    required this.attendancePercent,
    required this.sessionLabels,
  });

  final String studentId;
  final String name;
  final String registrationNumber;
  final int attendancePercent;

  /// Session id → Present / Absent / Pending / null (session still open).
  final Map<String, String?> sessionLabels;
}

/// Consolidated roll for one attendance list (matches SessionCheckInsScreen logic).
class AttendanceListRollData {
  const AttendanceListRollData({
    required this.list,
    required this.sessions,
    required this.students,
  });

  final AttendanceList list;
  final List<AttendanceSession> sessions;
  final List<AttendanceListRollStudentRow> students;

  int get rosterCount => students.length;

  int get presentRollRows {
    var n = 0;
    for (final s in students) {
      for (final label in s.sessionLabels.values) {
        if (label == 'Present') n++;
      }
    }
    return n;
  }

  int get pendingRollRows {
    var n = 0;
    for (final s in students) {
      for (final label in s.sessionLabels.values) {
        if (label == kRollLabelPending) n++;
      }
    }
    return n;
  }
  int get absentRollRows {
    var n = 0;
    for (final s in students) {
      for (final label in s.sessionLabels.values) {
        if (label == kRollLabelAbsent) n++;
      }
    }
    return n;
  }
}

String _fmtSessionDate(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

/// Builds consolidated roll data for [list] from the in-memory [AttendanceStore].
Future<AttendanceListRollData> buildAttendanceListRoll(
  AttendanceList list, {
  RollPendingContext? pendingContext,
}) async {
  final pending = pendingContext ?? await RollPendingContext.load();
  final studentsById = AttendanceStore.rosterStudentMapForList(list.id);
  final listSessions = AttendanceStore.sessionsForListNewestFirst(list.id);
  final listSessionIds = listSessions.map((s) => s.id).toSet();
  final listRecords = AttendanceStore.attendanceRecords
      .where((r) => listSessionIds.contains(r.sessionId))
      .toList();

  final studentIds = AttendanceStore.rollStudentIdsForList(list.id);

  final studentIdsByKey = <String, List<String>>{};
  for (final sid in studentIds) {
    final reg =
        (studentsById[sid]?.registrationNumber ?? '—').trim().toUpperCase();
    final key = reg.isEmpty || reg == '—' ? 'sid:$sid' : 'reg:$reg';
    (studentIdsByKey[key] ??= <String>[]).add(sid);
  }

  final rollRowsByKey = <String, List<AttendanceRecord>>{};
  final keyByStudentId = <String, String>{};
  for (final entry in studentIdsByKey.entries) {
    for (final sid in entry.value) {
      keyByStudentId[sid] = entry.key;
    }
  }
  for (final r in listRecords) {
    final key = keyByStudentId[r.studentId];
    if (key == null) continue;
    (rollRowsByKey[key] ??= <AttendanceRecord>[]).add(r);
  }

  final rollKeys = studentIdsByKey.keys.toList()
    ..sort((a, b) {
      final aSid = studentIdsByKey[a]!.first;
      final bSid = studentIdsByKey[b]!.first;
      return (studentsById[aSid]?.name ?? 'Unknown')
          .toLowerCase()
          .compareTo((studentsById[bSid]?.name ?? 'Unknown').toLowerCase());
    });

  final studentRows = <AttendanceListRollStudentRow>[];
  for (final k in rollKeys) {
    final ids = studentIdsByKey[k]!;
    final sid = ids.first;
    final student = studentsById[sid];
    final rows = rollRowsByKey[k] ?? const <AttendanceRecord>[];

    String? cellLabelForSession(AttendanceSession s) {
      return rollCellLabelForStudentSession(
        session: s,
        studentId: sid,
        recordsForStudent: rows,
        pending: pending,
      );
    }

    final rateSessions =
        listSessions.where((s) => s.countsTowardRollStats).toList();
    final rateCounts = rollRateCountsForStudentOnList(
      studentId: sid,
      listId: list.id,
      completedSessions: rateSessions,
      recordsForStudent: rows,
      pending: pending,
    );
    final percent = rateCounts.percentRounded;

    final sessionLabels = <String, String?>{
      for (final s in listSessions) s.id: cellLabelForSession(s),
    };

    studentRows.add(
      AttendanceListRollStudentRow(
        studentId: sid,
        name: student?.name ??
            AttendanceStore.resolveStudentForRoll(
              sid,
              listId: list.id,
              cache: studentsById,
            )?.name ??
            'Unknown',
        registrationNumber: student?.registrationNumber ?? '—',
        attendancePercent: percent,
        sessionLabels: sessionLabels,
      ),
    );
  }

  return AttendanceListRollData(
    list: list,
    sessions: listSessions,
    students: studentRows,
  );
}

String attendanceListRollPrintTitle(AttendanceListRollData roll) =>
    '${roll.list.displayTitle} — attendance roll';

String buildAttendanceListRollPlainText(AttendanceListRollData roll) {
  final buf = StringBuffer()
    ..writeln(attendanceListRollPrintTitle(roll))
    ..writeln('Roster: ${roll.rosterCount} · Sessions: ${roll.sessions.length}')
    ..writeln('Present rows: ${roll.presentRollRows} · Pending rows: ${roll.pendingRollRows} · Absent rows: ${roll.absentRollRows}')
    ..writeln('');
  final header = [
    '%',
    'Student',
    'Reg #',
    ...roll.sessions.map((s) => _fmtSessionDate(s.startTime)),
  ];
  buf.writeln(header.join('\t'));
  for (final row in roll.students) {
    final cells = [
      '${row.attendancePercent}%',
      row.name,
      row.registrationNumber,
      ...roll.sessions.map((s) => row.sessionLabels[s.id] ?? '—'),
    ];
    buf.writeln(cells.join('\t'));
  }
  return buf.toString();
}
