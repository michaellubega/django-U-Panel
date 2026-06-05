import '../attendance/models/attendance_models.dart';
import 'attendance_list_roll.dart';
import '../notices/create_notice_screen.dart' show NoticeAudienceKind;
import '../notices/data/notices_repository.dart';

/// RFC-style CSV cell (quotes if needed).
String reportCsvCell(String? raw) {
  final t = raw ?? '';
  if (t.contains(',') ||
      t.contains('"') ||
      t.contains('\n') ||
      t.contains('\r')) {
    return '"${t.replaceAll('"', '""')}"';
  }
  return t;
}

String _iso(DateTime d) => d.toIso8601String();

/// Per class list: roster size, session and roll counts.
/// When [listIds] is non-null, only those lists are included.
String buildAttendanceListsSummaryCsv({Set<String>? listIds}) {
  final lines = <String>[
    [
      'list_id',
      'list_title',
      'status',
      'year',
      'sem',
      'program',
      'room',
      'time',
      'lecturer_uid',
      'sign_in_students',
      'session_count',
      'roll_rows',
      'present_rows',
      'absent_rows',
    ].join(','),
  ];

  for (final l in List<AttendanceList>.from(AttendanceStore.lists)
    ..sort(compareAttendanceListsNewestFirst)) {
    if (listIds != null && !listIds.contains(l.id)) continue;
    final enrolled = AttendanceStore.studentIdsSignedIntoList(l.id).length;
    final sess = AttendanceStore.sessionsForListNewestFirst(l.id);
    var roll = 0, pres = 0, abs = 0;
    for (final r in AttendanceStore.attendanceRecords) {
      final sid = AttendanceStore.sessionById(r.sessionId)?.listId;
      if (sid != l.id) continue;
      roll++;
      if (r.present) {
        pres++;
      } else {
        abs++;
      }
    }
    lines.add([
      reportCsvCell(l.id),
      reportCsvCell(l.displayTitle),
      reportCsvCell(l.status.name),
      reportCsvCell(l.year),
      reportCsvCell(l.sem),
      reportCsvCell(l.program.label),
      reportCsvCell(l.room),
      reportCsvCell(l.time),
      reportCsvCell(l.lecturerUid),
      '$enrolled',
      '${sess.length}',
      '$roll',
      '$pres',
      '$abs',
    ].join(','));
  }
  return '${lines.join('\n')}\n';
}

/// Consolidated roll for one list (student × session present/absent).
String buildSingleListRollCsv(AttendanceList list) {
  final roll = buildAttendanceListRoll(list);
  final lines = <String>[
    [
      'attendance_percent',
      'student_name',
      'student_reg',
      ...roll.sessions.map(
        (s) =>
            'session_${s.startTime.toIso8601String().split('T').first}_${s.sessionCode}',
      ),
    ].join(','),
  ];
  for (final row in roll.students) {
    lines.add([
      '${row.attendancePercent}',
      reportCsvCell(row.name),
      reportCsvCell(row.registrationNumber),
      ...roll.sessions.map((s) => reportCsvCell(row.sessionLabels[s.id] ?? '—')),
    ].join(','));
  }
  return '${lines.join('\n')}\n';
}

/// One row per stored attendance record (session roll / check-in).
/// When [listIds] is non-null, only records for those lists are included.
String buildAttendanceRecordsCsv({Set<String>? listIds}) {
  final lines = <String>[
    [
      'record_id',
      'session_id',
      'session_code',
      'session_status',
      'session_start',
      'session_end',
      'list_id',
      'list_title',
      'student_id',
      'student_reg',
      'student_name',
      'course',
      'present',
      'verified',
      'timestamp',
    ].join(','),
  ];

  final students = AttendanceStore.studentMapById();
  for (final r in List<AttendanceRecord>.from(AttendanceStore.attendanceRecords)
    ..sort((a, b) => b.timestamp.compareTo(a.timestamp))) {
    final sess = AttendanceStore.sessionById(r.sessionId);
    final list = sess != null ? AttendanceStore.listById(sess.listId) : null;
    if (listIds != null && (list == null || !listIds.contains(list.id))) {
      continue;
    }
    final st = students[r.studentId];
    lines.add([
      reportCsvCell(r.id),
      reportCsvCell(r.sessionId),
      reportCsvCell(sess?.sessionCode),
      reportCsvCell(sess?.status.name),
      reportCsvCell(sess != null ? _iso(sess.startTime) : ''),
      reportCsvCell(sess != null ? _iso(sess.endTime) : ''),
      reportCsvCell(sess?.listId),
      reportCsvCell(list?.displayTitle),
      reportCsvCell(r.studentId),
      reportCsvCell(st?.registrationNumber),
      reportCsvCell(st?.name),
      reportCsvCell(r.course),
      '${r.present}',
      '${r.verified}',
      _iso(r.timestamp),
    ].join(','));
  }
  return '${lines.join('\n')}\n';
}

/// Sign-in events (roster joins) — useful as an “activity” trail.
String buildSignInsCsv() {
  final lines = <String>[
    [
      'signed_in_at',
      'student_id',
      'student_reg',
      'student_name',
      'list_id',
      'list_title',
      'course',
    ].join(','),
  ];
  final students = AttendanceStore.studentMapById();
  final sorted = List<SignInRecord>.from(AttendanceStore.signIns)
    ..sort((a, b) => b.signedInAt.compareTo(a.signedInAt));
  for (final s in sorted) {
    final list = AttendanceStore.listById(s.listId);
    final st = students[s.studentId];
    lines.add([
      _iso(s.signedInAt),
      reportCsvCell(s.studentId),
      reportCsvCell(st?.registrationNumber),
      reportCsvCell(st?.name),
      reportCsvCell(s.listId),
      reportCsvCell(list?.displayTitle),
      reportCsvCell(s.course),
    ].join(','));
  }
  return '${lines.join('\n')}\n';
}

String _audienceLabel(NoticeAudienceKind k) {
  switch (k) {
    case NoticeAudienceKind.classList:
      return 'classList';
    case NoticeAudienceKind.student:
      return 'student';
    case NoticeAudienceKind.allAppUsers:
      return 'allAppUsers';
  }
}

/// Published notices (most recent first).
String buildNoticesCsv(List<NoticeRecord> notices) {
  final lines = <String>[
    [
      'id',
      'title',
      'author',
      'created_at',
      'scheduled_for',
      'expires_at',
      'audience',
      'send_push',
      'target_list_id',
      'target_list_title',
      'session_code',
      'kind',
      'body',
    ].join(','),
  ];
  for (final n in notices) {
    lines.add([
      reportCsvCell(n.id),
      reportCsvCell(n.title),
      reportCsvCell(n.author),
      _iso(n.createdAt),
      reportCsvCell(n.scheduledFor != null ? _iso(n.scheduledFor!) : ''),
      reportCsvCell(n.expiresAt != null ? _iso(n.expiresAt!) : ''),
      _audienceLabel(n.audience),
      '${n.sendPush}',
      reportCsvCell(n.targetListId),
      reportCsvCell(n.targetListTitle),
      reportCsvCell(n.sessionCode),
      reportCsvCell(n.kind),
      reportCsvCell(n.body),
    ].join(','));
  }
  return '${lines.join('\n')}\n';
}
