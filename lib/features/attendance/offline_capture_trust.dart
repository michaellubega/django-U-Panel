import 'check_in_validation.dart';
import 'data/pending_check_in_queue.dart';
import 'data/pending_session_code_queue.dart';
import 'models/attendance_models.dart';

/// Locally queued GPS check-ins are trusted for roll/sync when they belong to
/// [session] (same session id + list scope). Does not match other sessions.
bool offlineQueuedCheckInTrustsPresent(
  PendingCheckInEntry entry,
  AttendanceSession session,
) {
  if (entry.sessionId.trim() != session.id) return false;
  if (entry.listId.isNotEmpty && entry.listId != session.listId) {
    return false;
  }
  return true;
}

/// Offline queue row for the same session — not cross-session time/GPS guessing.
bool offlineOrMetadataQueuedCheckInTrustsPresent(
  PendingCheckInEntry entry,
  AttendanceSession session,
) {
  return offlineQueuedCheckInTrustsPresent(entry, session);
}

/// Locally queued session-code captures require matching join code, student,
/// capture time within session bounds, and GPS when required.
bool offlineQueuedSessionCodeTrustsPresent({
  required PendingSessionCodeEntry entry,
  required AttendanceSession session,
  required String studentRegistrationNumber,
}) {
  if (entry.status == PendingSessionCodeStatus.invalidOrExpired) return false;
  if (entry.status == PendingSessionCodeStatus.deviceBlocked) return false;
  final reg = entry.registrationNumber.trim().toUpperCase();
  final studentReg = studentRegistrationNumber.trim().toUpperCase();
  if (studentReg.isNotEmpty && reg != studentReg) return false;
  final entryCode = normalizeSessionCodeInput(entry.sessionCodeRaw);
  final sessionCode = normalizeSessionCodeInput(session.sessionCode);
  if (entryCode.isEmpty || sessionCode.isEmpty || entryCode != sessionCode) {
    return false;
  }
  if (!isTimestampWithinSessionBounds(session, entry.capturedAt)) {
    return false;
  }
  return pendingReplayLocationOk(session, entry.latitude, entry.longitude);
}

/// True when [entry] should block [finalizeRollForSession] for [session].
bool pendingSessionCodeBlocksSessionFinalize(
  PendingSessionCodeEntry entry,
  AttendanceSession session,
) {
  if (entry.status == PendingSessionCodeStatus.invalidOrExpired) return false;
  if (entry.sessionId == session.id) return true;
  return offlineQueuedSessionCodeTrustsPresent(
    entry: entry,
    session: session,
    studentRegistrationNumber: entry.registrationNumber,
  );
}
