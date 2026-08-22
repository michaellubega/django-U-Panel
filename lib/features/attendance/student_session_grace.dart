import 'data/pending_retention.dart';
import 'models/attendance_models.dart';

/// Whether [session] may be marked absent for [studentId] on [listId].
///
/// Grace ends when either:
/// - [PendingRetention.unverifiedPending] (7 days) has passed since [session.endTime], or
/// - a later completed session on the same list has a **present** record for
///   this student (evidence they came online and prior queues should have synced).
bool studentSessionGraceExpired({
  required AttendanceSession session,
  required String studentId,
  required String listId,
  required Iterable<AttendanceRecord> recordsForStudent,
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  if (PendingRetention.sessionGraceExpired(session.endTime, at)) {
    return true;
  }
  return studentHasLaterResolvedSessionOnList(
    session: session,
    studentId: studentId,
    listId: listId,
    recordsForStudent: recordsForStudent,
  );
}

/// Same as [studentSessionGraceExpired] when a registration maps to several ids.
bool registrationSessionGraceExpired({
  required AttendanceSession session,
  required String listId,
  required Iterable<String> studentIds,
  required Iterable<AttendanceRecord> recordsForStudents,
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  if (PendingRetention.sessionGraceExpired(session.endTime, at)) {
    return true;
  }
  for (final sid in studentIds) {
    if (studentHasLaterResolvedSessionOnList(
      session: session,
      studentId: sid,
      listId: listId,
      recordsForStudent:
          recordsForStudents.where((r) => r.studentId == sid),
    )) {
      return true;
    }
  }
  return false;
}

/// True when a later session on [listId] already has a **present** roll row.
bool studentHasLaterResolvedSessionOnList({
  required AttendanceSession session,
  required String studentId,
  required String listId,
  required Iterable<AttendanceRecord> recordsForStudent,
}) {
  for (final later in AttendanceStore.sessionsForListNewestFirst(listId)) {
    if (later.id == session.id) continue;
    if (!later.endTime.isAfter(session.endTime)) continue;
    if (!later.countsTowardRollStats) continue;
    final rec = _bestRollRecordForSession(
      sessionId: later.id,
      recordsForStudent: recordsForStudent,
    );
    if (rec != null && rec.present) return true;
  }
  return false;
}

AttendanceRecord? _bestRollRecordForSession({
  required String sessionId,
  required Iterable<AttendanceRecord> recordsForStudent,
}) {
  AttendanceRecord? best;
  for (final r in recordsForStudent) {
    if (r.sessionId != sessionId) continue;
    best = _mergeRollRecord(best, r);
  }
  return best;
}

AttendanceRecord? _mergeRollRecord(AttendanceRecord? a, AttendanceRecord b) {
  if (a == null) return b;
  if (a.present && a.verified) return a;
  if (b.present && b.verified) return b;
  if (a.present && !b.present) return a;
  if (b.present && !a.present) return b;
  if (a.present && b.present) {
    return a.verified ? a : (b.verified ? b : a);
  }
  return b.timestamp.isAfter(a.timestamp) ? b : a;
}
