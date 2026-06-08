import '../models/attendance_models.dart';
import 'pending_check_in_queue.dart';
import 'pending_list_create_queue.dart';
import 'pending_session_code_queue.dart';
import 'pending_session_code_sync.dart';
import 'pending_session_create_queue.dart';

/// Purges in-memory [AttendanceStore] rows and durable offline queues for a
/// deleted attendance list (lecturer delete or student sync after server cascade).
///
/// Local coverage: lists, sessions, sign-ins, records (via [AttendanceStore.removeList]),
/// pending list creates, pending check-ins, pending session creates, pending session
/// codes (+ side effects). Hive attendance snapshots are rewritten by the caller.
/// Firestore child docs and server-only rows ([attendance_records],
/// [check_in_attempts]) are removed by [AttendanceRepository.removeList] and
/// `onAttendanceListDeleted`.
class AttendanceListPurge {
  AttendanceListPurge._();

  static Future<void> purgeLocalDataForList(String listId) async {
    final trimmed = listId.trim();
    if (trimmed.isEmpty) return;

    final sessionIdsForList = AttendanceStore.sessions
        .where((s) => s.listId == trimmed)
        .map((s) => s.id)
        .toSet();

    AttendanceStore.removeList(trimmed);

    await PendingListCreateQueue.removeByListId(trimmed);

    final checkIns = await PendingCheckInQueue.loadAll();
    final keptCheckIns =
        checkIns.where((e) => e.listId != trimmed).toList();
    if (keptCheckIns.length != checkIns.length) {
      await PendingCheckInQueue.saveAll(keptCheckIns);
    }

    final sessionCreates = await PendingSessionCreateQueue.loadAll();
    final keptCreates =
        sessionCreates.where((e) => e.listId != trimmed).toList();
    if (keptCreates.length != sessionCreates.length) {
      await PendingSessionCreateQueue.saveAll(keptCreates);
    }

    final codes = await PendingSessionCodeQueue.loadAll();
    final keptCodes = <PendingSessionCodeEntry>[];
    for (final e in codes) {
      final dropByList = e.listId == trimmed;
      final dropBySession = e.sessionId != null &&
          sessionIdsForList.contains(e.sessionId!.trim());
      if (dropByList || dropBySession) {
        PendingSessionCodeSync.discardLocalAttendanceSideEffects(e);
        continue;
      }
      keptCodes.add(e);
    }
    if (keptCodes.length != codes.length) {
      await PendingSessionCodeQueue.saveAll(keptCodes);
    }
  }
}
