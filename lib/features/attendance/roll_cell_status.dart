import 'check_in_validation.dart';
import 'models/attendance_models.dart';
import 'data/pending_check_in_queue.dart';
import 'data/pending_retention.dart';
import 'data/pending_session_code_queue.dart';
import 'data/pending_session_create_queue.dart';

/// Roll cell labels shown in attendance tables.
const kRollLabelPresent = 'Present';
const kRollLabelAbsent = 'Absent';
const kRollLabelPending = 'Pending';

/// True when the lecturer session is missing code, time bounds, or geofence.
bool sessionStudentCheckInMetadataIncomplete(AttendanceSession session) {
  final code = normalizeSessionCodeInput(session.sessionCode);
  if (!isValidJoinCodeFormat(code)) return true;
  if (session.remoteLearning) return false;
  return !isSessionGeofenceConfigured(session);
}

/// Pending only while student evidence is missing code, time, GPS, or session link.
bool pendingCheckInMissingMetadataForPending(PendingCheckInEntry entry) {
  if (entry.sessionId.trim().isEmpty) return true;
  final session = AttendanceStore.sessionById(entry.sessionId);
  if (session?.remoteLearning == true) return false;
  if (!isValidCheckInCoordinates(entry.latitude, entry.longitude)) return true;
  return false;
}

bool pendingSessionCodeMissingMetadataForPending(PendingSessionCodeEntry entry) {
  if (!isValidJoinCodeFormat(
      normalizeSessionCodeInput(entry.sessionCodeRaw))) {
    return true;
  }
  if (entry.sessionId == null || entry.sessionId!.trim().isEmpty) return true;
  final session = AttendanceStore.sessionById(entry.sessionId!);
  if (session?.remoteLearning != true &&
      !isValidCheckInCoordinates(entry.latitude, entry.longitude)) {
    return true;
  }
  return false;
}

/// True when a local present row has enough evidence to label Present while
/// server verification is still in flight (session link + GPS when required).
bool attendanceRecordHasCompleteCheckInMetadata(
  AttendanceRecord record,
  AttendanceSession session,
) {
  if (record.sessionId.trim().isEmpty) return false;
  if (session.remoteLearning) return true;
  return isValidCheckInCoordinates(record.latitude, record.longitude);
}

/// Local-only queues that affect how roll cells are labeled.
class RollPendingContext {
  const RollPendingContext({
    this.sessionIdsAwaitingUpload = const {},
    this.pendingPresentStudentIdsBySession = const {},
    this.sessionsWithIncompleteMetadata = const {},
  });

  const RollPendingContext.empty()
      : sessionIdsAwaitingUpload = const {},
        pendingPresentStudentIdsBySession = const {},
        sessionsWithIncompleteMetadata = const {};

  /// Sessions started offline that are not on Firestore yet.
  final Set<String> sessionIdsAwaitingUpload;

  /// Students waiting on incomplete check-in metadata per session.
  final Map<String, Set<String>> pendingPresentStudentIdsBySession;

  /// Sessions whose lecturer-side metadata is not ready for check-in.
  final Set<String> sessionsWithIncompleteMetadata;

  static Future<RollPendingContext> load() async {
    final creates = await PendingSessionCreateQueue.loadAll();
    final checkIns = await PendingCheckInQueue.loadAll();
    final pendingCodes = await PendingSessionCodeQueue.loadAll();

    final awaitingUpload = creates.map((e) => e.sessionId).toSet();
    final pendingBySession = <String, Set<String>>{};
    final incompleteSessions = <String>{};

    for (final s in AttendanceStore.sessions) {
      if (sessionStudentCheckInMetadataIncomplete(s)) {
        incompleteSessions.add(s.id);
      }
    }

    void addPending(String sessionId, String studentId) {
      if (sessionId.isEmpty || studentId.isEmpty) return;
      (pendingBySession[sessionId] ??= <String>{}).add(studentId);
    }

    for (final e in checkIns) {
      if (!pendingCheckInMissingMetadataForPending(e)) continue;
      final session = AttendanceStore.sessionById(e.sessionId);
      if (session != null &&
          e.listId.isNotEmpty &&
          e.listId != session.listId) {
        continue;
      }
      addPending(e.sessionId, e.studentId);
    }

    for (final e in pendingCodes) {
      if (!pendingSessionCodeMissingMetadataForPending(e)) continue;
      final sid = e.sessionId?.trim();
      if (sid == null || sid.isEmpty) continue;
      final student = AttendanceStore.findStudentByReg(e.registrationNumber);
      if (student == null) continue;
      addPending(sid, student.id);
    }

    return RollPendingContext(
      sessionIdsAwaitingUpload: awaitingUpload,
      pendingPresentStudentIdsBySession: pendingBySession,
      sessionsWithIncompleteMetadata: incompleteSessions,
    );
  }

  bool sessionAwaitingUpload(String sessionId) =>
      sessionIdsAwaitingUpload.contains(sessionId);

  bool studentHasPendingPresent(String sessionId, String studentId) =>
      pendingPresentStudentIdsBySession[sessionId]?.contains(studentId) ??
      false;

  bool sessionMetadataIncomplete(String sessionId) =>
      sessionsWithIncompleteMetadata.contains(sessionId);
}

bool rollGracePeriodExpired(AttendanceSession session, DateTime now) =>
    PendingRetention.sessionGraceExpired(session.endTime, now);

/// Resolves one student × session cell for roll tables and stats.
String? rollCellLabelForStudentSession({
  required AttendanceSession session,
  required String studentId,
  required List<AttendanceRecord> recordsForStudent,
  RollPendingContext pending = const RollPendingContext.empty(),
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  final enrolledAt = AttendanceStore.earliestSignInAtForStudentOnList(
    session.listId,
    studentId,
  );
  final missedBeforeJoin =
      enrolledAt != null && session.endTime.isBefore(enrolledAt);

  AttendanceRecord? best;
  for (final r in recordsForStudent) {
    if (r.sessionId != session.id) continue;
    best = _mergeRollRecord(best, r);
  }

  // Match [AttendanceStore.rollStatsForRegistrationOnList]: any local present row
  // counts immediately — including unverified / still-uploading check-ins.
  if (best != null && best.present) {
    return kRollLabelPresent;
  }

  if (pending.sessionAwaitingUpload(session.id) ||
      pending.sessionMetadataIncomplete(session.id)) {
    return kRollLabelPending;
  }

  if (pending.studentHasPendingPresent(session.id, studentId)) {
    return kRollLabelPending;
  }

  if (best != null) {
    if (!session.countsTowardRollStats) return null;
    return kRollLabelAbsent;
  }

  if (!session.countsTowardRollStats) return null;

  if (missedBeforeJoin) return kRollLabelAbsent;
  if (!rollGracePeriodExpired(session, at)) {
    return null;
  }
  return kRollLabelAbsent;
}

/// Best attendance row for one student × session (present beats absent).
AttendanceRecord? mergedRollRecordForStudentSession({
  required String sessionId,
  required List<AttendanceRecord> recordsForStudent,
}) {
  AttendanceRecord? best;
  for (final r in recordsForStudent) {
    if (r.sessionId != sessionId) continue;
    best = _mergeRollRecord(best, r);
  }
  return best;
}

/// Best row for a session card — matches profile % (session id or same list + code).
AttendanceRecord? mergedRollRecordForSession({
  required AttendanceSession session,
  required Set<String> studentIds,
  required List<AttendanceRecord> recordsForStudents,
}) {
  if (studentIds.isEmpty) return null;
  final code = normalizeSessionCodeInput(session.sessionCode);
  AttendanceRecord? best;
  for (final r in recordsForStudents) {
    if (!studentIds.contains(r.studentId)) continue;
    final idMatch = r.sessionId == session.id;
    var codeMatch = false;
    if (!idMatch) {
      final recSession = AttendanceStore.sessionById(r.sessionId);
      codeMatch = recSession != null &&
          recSession.listId == session.listId &&
          normalizeSessionCodeInput(recSession.sessionCode) == code;
    }
    if (!idMatch && !codeMatch) continue;
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

String? rollCellLabelFromRecords({
  required AttendanceSession session,
  required String studentId,
  required List<AttendanceRecord> recordsForStudent,
  RollPendingContext pending = const RollPendingContext.empty(),
  DateTime? now,
}) {
  return rollCellLabelForStudentSession(
    session: session,
    studentId: studentId,
    recordsForStudent: recordsForStudent,
    pending: pending,
    now: now,
  );
}

/// Counts only resolved Present / Absent rows for attendance percentage.
bool rollCellCountsTowardRate(String? label) =>
    label == kRollLabelPresent || label == kRollLabelAbsent;

/// Present / total for rate columns — uses every [AttendanceRecord] on file
/// for the session (`present` true or false), then implicit absent when there
/// is no record (pre-join miss or grace expired).
RollRateCounts rollRateCountsForStudentOnList({
  required String studentId,
  required String listId,
  required Iterable<AttendanceSession> completedSessions,
  required List<AttendanceRecord> recordsForStudent,
  RollPendingContext pending = const RollPendingContext.empty(),
  DateTime? now,
}) {
  final at = now ?? DateTime.now();
  final enrolledAt = AttendanceStore.earliestSignInAtForStudentOnList(
    listId,
    studentId,
  );
  var total = 0;
  var present = 0;
  final countedSessionIds = <String>{};

  AttendanceRecord? recordForSession(String sessionId) {
    AttendanceRecord? best;
    for (final r in recordsForStudent) {
      if (r.sessionId != sessionId) continue;
      best = _mergeRollRecord(best, r);
    }
    return best;
  }

  for (final sess in completedSessions) {
    if (!sess.countsTowardRollStats) continue;
    final rec = recordForSession(sess.id);
    if (rec != null) {
      total++;
      if (rec.present) present++;
      countedSessionIds.add(sess.id);
      continue;
    }
    if (pending.studentHasPendingPresent(sess.id, studentId)) {
      continue;
    }
    if (pending.sessionAwaitingUpload(sess.id) ||
        pending.sessionMetadataIncomplete(sess.id)) {
      continue;
    }
    final missedBeforeJoin =
        enrolledAt != null && sess.endTime.isBefore(enrolledAt);
    if (!missedBeforeJoin && !rollGracePeriodExpired(sess, at)) {
      continue;
    }
    total++;
    countedSessionIds.add(sess.id);
  }

  for (final r in recordsForStudent) {
    if (countedSessionIds.contains(r.sessionId)) continue;
    final sess = AttendanceStore.sessionById(r.sessionId);
    if (sess == null || sess.listId != listId || !sess.countsTowardRollStats) {
      continue;
    }
    total++;
    if (r.present) present++;
    countedSessionIds.add(r.sessionId);
  }

  return RollRateCounts(present: present, total: total);
}

class RollRateCounts {
  const RollRateCounts({required this.present, required this.total});

  final int present;
  final int total;

  int get percentRounded =>
      total <= 0 ? 0 : ((100 * present) / total).round().clamp(0, 100);
}
