import 'data/pending_check_in_queue.dart';
import 'data/pending_retention.dart';
import 'data/pending_session_code_queue.dart';
import 'models/attendance_models.dart';
import 'offline_capture_trust.dart';

/// True when [studentId] still has unexpired local upload work for [session].
///
/// Pending evidence always outranks implicit absent / grace backfill.
Future<bool> studentHasUnexpiredPendingEvidenceForSession({
  required AttendanceSession session,
  required String studentId,
  DateTime? now,
}) async {
  final at = now ?? DateTime.now();
  final sessionId = session.id;
  final listId = session.listId;

  for (final e in await PendingCheckInQueue.loadAll()) {
    if (PendingRetention.isExpired(e.pendingSince, at)) continue;
    if (e.studentId != studentId) continue;
    if (e.sessionId == sessionId) return true;
    if (e.listId.isNotEmpty &&
        e.listId == listId &&
        e.sessionId.isNotEmpty &&
        AttendanceStore.sessionById(e.sessionId)?.listId == listId) {
      final linked = AttendanceStore.sessionById(e.sessionId);
      if (linked != null &&
          normalizeSessionCodeInput(linked.sessionCode) ==
              normalizeSessionCodeInput(session.sessionCode)) {
        return true;
      }
    }
  }

  final student = AttendanceStore.students
      .where((s) => s.id == studentId)
      .firstOrNull;
  final reg = student?.registrationNumber.trim().toUpperCase() ?? '';
  if (reg.isEmpty) return false;

  for (final e in await PendingSessionCodeQueue.loadAll()) {
    if (PendingRetention.isExpired(e.pendingSince, at)) continue;
    if (e.registrationNumber.trim().toUpperCase() != reg) continue;
    if (e.status == PendingSessionCodeStatus.invalidOrExpired) continue;
    if (e.status == PendingSessionCodeStatus.deviceBlocked) continue;
    final sid = e.sessionId?.trim();
    if (sid != null && sid.isNotEmpty && sid == sessionId) return true;
    if (offlineQueuedSessionCodeTrustsPresent(
      entry: e,
      session: session,
      studentRegistrationNumber: reg,
    )) {
      return true;
    }
  }

  return false;
}
