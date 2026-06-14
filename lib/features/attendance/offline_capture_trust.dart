import 'check_in_validation.dart';
import 'data/pending_check_in_queue.dart';
import 'data/pending_session_code_queue.dart';
import 'models/attendance_models.dart';

/// Locally queued GPS check-ins are trusted for roll/sync even when live session
/// metadata (times, geofence centre, list fields) changed after offline capture.
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

/// Offline queue + matching capture metadata (time, code scope, GPS when required).
bool offlineOrMetadataQueuedCheckInTrustsPresent(
  PendingCheckInEntry entry,
  AttendanceSession session,
) {
  if (offlineQueuedCheckInTrustsPresent(entry, session)) return true;
  if (entry.listId.isNotEmpty && entry.listId != session.listId) {
    return false;
  }
  return isTimestampWithinSessionBounds(session, entry.capturedAt) &&
      positionQualifiesForPresentCorrection(
        session,
        entry.latitude,
        entry.longitude,
      );
}

/// Locally queued session-code captures are trusted when code + student match,
/// even if session id hints or metadata differ from the published session.
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
  return true;
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
