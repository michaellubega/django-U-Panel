import '../check_in_validation.dart';
import '../models/attendance_models.dart';
import 'attendance_repository.dart';
import 'pending_check_in_queue.dart';
import 'pending_retention.dart';
import 'pending_session_code_queue.dart';
import 'pending_session_code_sync.dart';
import 'pending_session_create_queue.dart';
import 'pending_session_create_sync.dart';
import 'package:flutter/foundation.dart';

import '../../../core/connectivity/app_connectivity.dart';

/// Drains locally queued check-ins after connectivity returns or on app resume.
///
/// Re-validates each entry against the **stored** capture time and coordinates
/// and the session loaded into [AttendanceStore] (after [loadAll]).
class AttendanceOfflineSync {
  AttendanceOfflineSync._();

  static bool _draining = false;

  /// Uploads pending work in order, then one [loadAll] so the store is not wiped
  /// mid-drain (which caused present/absent to flip when sessions started offline).
  static Future<void> drainAllInOrder() async {
    if (_draining) return;
    _draining = true;
    try {
      await purgeExpiredPendingOnly();
      await PendingSessionCreateSync.drain();
      await _drainCheckInsWithoutReload();
      await PendingSessionCodeSync.drainWithoutReload();
      if (AppConnectivity.instance.isOnline) {
        await AttendanceRepository.instance.loadAll(
          force: true,
          scopeToLecturerUid:
              AttendanceRepository.currentLecturerLoadScopeUid(),
        );
      }
    } finally {
      _draining = false;
    }
  }

  /// Removes queue rows past [PendingRetention.unverifiedPending] without network.
  static Future<void> purgeExpiredPendingOnly() async {
    final now = DateTime.now();
    final checkIns = await PendingCheckInQueue.loadAll();
    final keptCheckIns = checkIns
        .where((e) => !PendingRetention.isExpired(e.pendingSince, now))
        .toList();
    if (keptCheckIns.length != checkIns.length) {
      await PendingCheckInQueue.saveAll(keptCheckIns);
    }

    final codes = await PendingSessionCodeQueue.loadAll();
    final keptCodes = codes
        .where((e) => !PendingRetention.isExpired(e.pendingSince, now))
        .toList();
    if (keptCodes.length != codes.length) {
      await PendingSessionCodeQueue.saveAll(keptCodes);
    }

    final creates = await PendingSessionCreateQueue.loadAll();
    final keptCreates = creates
        .where((e) => !PendingRetention.isExpired(e.enqueuedAt, now))
        .toList();
    if (keptCreates.length != creates.length) {
      await PendingSessionCreateQueue.saveAll(keptCreates);
    }
  }

  /// Best-effort GPS check-in queue (no [loadAll] — caller runs after full drain).
  static Future<void> drain() => drainAllInOrder();

  static Future<void> _drainCheckInsWithoutReload() async {
    try {
      final pending = await PendingCheckInQueue.loadAll();
      if (pending.isEmpty) {
        return;
      }

      final now = DateTime.now();
      final afterExpiryPurge = <PendingCheckInEntry>[];
      var droppedExpired = 0;
      for (final e in pending) {
        if (PendingRetention.isExpired(e.pendingSince, now)) {
          droppedExpired++;
          continue;
        }
        afterExpiryPurge.add(e);
      }
      if (afterExpiryPurge.isEmpty) {
        await PendingCheckInQueue.saveAll(const []);
        if (droppedExpired > 0 && kDebugMode) {
          debugPrint(
            'AttendanceOfflineSync: disposed $droppedExpired expired pending check-in(s).',
          );
        }
        return;
      }

      var droppedInvalidTime = 0;
      var droppedInvalidDistance = 0;
      var droppedDuplicate = 0;
      var droppedDeviceBlocked = 0;
      var droppedExpiredSession = 0;
      final keep = <PendingCheckInEntry>[];
      for (final e in afterExpiryPurge) {
        final session = AttendanceStore.sessionById(e.sessionId);
        if (session == null) {
          if (PendingRetention.isExpired(e.pendingSince, now)) {
            droppedExpiredSession++;
            continue;
          }
          keep.add(e);
          continue;
        }
        if (!isTimestampWithinSessionBounds(session, e.capturedAt)) {
          droppedInvalidTime++;
          continue;
        }
        if (!isPositionWithinSession(session, e.latitude, e.longitude)) {
          droppedInvalidDistance++;
          continue;
        }
        final d = e.deviceId.trim();
        if (d.isNotEmpty &&
            AttendanceStore.hasPresentCheckInForDevice(
              e.sessionId,
              d,
              e.studentId,
            )) {
          droppedDeviceBlocked++;
          continue;
        }
        final record = e.toAttendanceRecord();
        if (AttendanceStore.hasCheckedIn(e.sessionId, e.studentId)) {
          final synced = await AttendanceRepository.instance
              .tryWriteAttendanceRecordDocument(record);
          if (!synced) {
            keep.add(e);
          } else {
            AttendanceStore.updateAttendanceRecord(record);
            droppedDuplicate++;
          }
          continue;
        }
        if (!AttendanceStore.addAttendanceRecordIfAbsent(record)) {
          final synced = await AttendanceRepository.instance
              .tryWriteAttendanceRecordDocument(record);
          if (!synced) {
            keep.add(e);
          } else {
            AttendanceStore.updateAttendanceRecord(record);
            droppedDuplicate++;
          }
          continue;
        }
        final synced = await AttendanceRepository.instance
            .tryWriteAttendanceRecordDocument(record);
        if (!synced) {
          AttendanceStore.removeAttendanceRecordById(record.id);
          keep.add(e);
        }
      }
      await PendingCheckInQueue.saveAll(keep);
      if (droppedInvalidTime > 0 ||
          droppedInvalidDistance > 0 ||
          droppedDuplicate > 0 ||
          droppedDeviceBlocked > 0 ||
          droppedExpired > 0 ||
          droppedExpiredSession > 0) {
        debugPrint(
          'AttendanceOfflineSync: dropped '
          '$droppedInvalidTime invalid-time, '
          '$droppedInvalidDistance out-of-radius, '
          '$droppedDuplicate duplicate, '
          '$droppedDeviceBlocked device-blocked, '
          '$droppedExpired+$droppedExpiredSession expired pending item(s).',
        );
      }
    } catch (_) {
      // Leave queue intact; next drain will retry.
    }
  }
}
