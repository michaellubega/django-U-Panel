import '../check_in_validation.dart';
import '../../../core/connectivity/app_connectivity.dart';
import '../models/attendance_models.dart';
import 'attendance_repository.dart';
import 'pending_retention.dart';
import 'pending_session_code_queue.dart';

class PendingSessionCodeSync {
  PendingSessionCodeSync._();

  static bool _running = false;

  static Future<void> drain() async {
    if (_running) return;
    _running = true;
    try {
      final all = await PendingSessionCodeQueue.loadAll();
      if (all.isEmpty) {
        await PendingSessionCodeQueue.saveLastSyncResult(
          PendingSessionSyncResult(
            ranAt: DateTime.now(),
            startedCount: 0,
            remainingCount: 0,
            autoSubmittedCount: 0,
            needsRegistrationCount: 0,
            invalidMarkedCount: 0,
            invalidRemovedCount: 0,
            deviceBlockedCount: 0,
          ),
        );
        return;
      }

      final now = DateTime.now();
      final keep = <PendingSessionCodeEntry>[];
      var invalidRemovedCount = 0;

      // Drop rows older than retention even while offline.
      for (final entry in all) {
        if (PendingRetention.isExpired(entry.pendingSince, now)) {
          invalidRemovedCount++;
          continue;
        }
        keep.add(entry);
      }

      if (!AppConnectivity.instance.isOnline) {
        await PendingSessionCodeQueue.saveAll(keep);
        await PendingSessionCodeQueue.saveLastSyncResult(
          PendingSessionSyncResult(
            ranAt: now,
            startedCount: all.length,
            remainingCount: keep.length,
            autoSubmittedCount: 0,
            needsRegistrationCount: 0,
            invalidMarkedCount: 0,
            invalidRemovedCount: invalidRemovedCount,
            deviceBlockedCount: 0,
          ),
        );
        return;
      }

      final processed = await _processEntriesOnline(keep, now);
      await PendingSessionCodeQueue.saveAll(processed.remaining);
      await PendingSessionCodeQueue.saveLastSyncResult(
        PendingSessionSyncResult(
          ranAt: now,
          startedCount: all.length,
          remainingCount: processed.remaining.length,
          autoSubmittedCount: processed.autoSubmittedCount,
          needsRegistrationCount: processed.needsRegistrationCount,
          invalidMarkedCount: processed.invalidMarkedCount,
          invalidRemovedCount:
              invalidRemovedCount + processed.invalidRemovedCount,
          deviceBlockedCount: processed.deviceBlockedCount,
        ),
      );
    } finally {
      _running = false;
    }
  }

  /// Session-code queue only (no [loadAll]). Use [AttendanceOfflineSync.drainAllInOrder].
  static Future<void> drainWithoutReload() async {
    if (_running) return;
    _running = true;
    try {
      final all = await PendingSessionCodeQueue.loadAll();
      if (all.isEmpty) return;
      if (!AppConnectivity.instance.isOnline) return;

      final now = DateTime.now();
      final keep = <PendingSessionCodeEntry>[];
      for (final entry in all) {
        if (PendingRetention.isExpired(entry.pendingSince, now)) continue;
        keep.add(entry);
      }
      if (keep.isEmpty) {
        await PendingSessionCodeQueue.saveAll(const []);
        return;
      }
      final processed = await _processEntriesOnline(keep, now);
      await PendingSessionCodeQueue.saveAll(processed.remaining);
    } finally {
      _running = false;
    }
  }

  static Future<
      ({
        List<PendingSessionCodeEntry> remaining,
        int autoSubmittedCount,
        int needsRegistrationCount,
        int invalidMarkedCount,
        int invalidRemovedCount,
        int deviceBlockedCount,
      })> _processEntriesOnline(
    List<PendingSessionCodeEntry> keep,
    DateTime now,
  ) async {
    final onlineKeep = <PendingSessionCodeEntry>[];
    var autoSubmittedCount = 0;
    var needsRegistrationCount = 0;
    var invalidMarkedCount = 0;
    var invalidRemovedCount = 0;
    var deviceBlockedCount = 0;

    for (final entry in keep) {
      final updated = await _tryProcess(entry, now);
      if (updated == null) {
        autoSubmittedCount++;
        continue;
      }
      if (updated.status == PendingSessionCodeStatus.invalidOrExpired) {
        final marked = updated.invalidMarkedAt ?? updated.pendingSince;
        if (PendingRetention.isExpired(marked, now)) {
          invalidRemovedCount++;
          continue;
        }
        invalidMarkedCount++;
      } else if (updated.status == PendingSessionCodeStatus.needsRegistration) {
        needsRegistrationCount++;
      } else if (updated.status == PendingSessionCodeStatus.deviceBlocked) {
        deviceBlockedCount++;
      }
      onlineKeep.add(updated);
    }
    return (
      remaining: onlineKeep,
      autoSubmittedCount: autoSubmittedCount,
      needsRegistrationCount: needsRegistrationCount,
      invalidMarkedCount: invalidMarkedCount,
      invalidRemovedCount: invalidRemovedCount,
      deviceBlockedCount: deviceBlockedCount,
    );
  }

  static Future<PendingSessionCodeEntry?> _tryProcess(
    PendingSessionCodeEntry entry,
    DateTime now,
  ) async {
    final session = await AttendanceRepository.instance
        .resolveSessionByCodeAtTime(
          rawCode: entry.sessionCodeRaw,
          capturedAt: entry.capturedAt,
        );
    if (session == null) {
      return entry.copyWith(
        status: PendingSessionCodeStatus.queued,
        note:
            'Waiting for session to sync (code ${normalizeSessionCodeInput(entry.sessionCodeRaw)}). '
            'Kept up to ${PendingRetention.unverifiedPending.inDays} days.',
        invalidMarkedAt: null,
      );
    }

    var list = AttendanceStore.listById(session.listId);
    list ??= await AttendanceRepository.instance.resolveListById(session.listId);
    if (list == null) {
      return entry.copyWith(
        sessionId: session.id,
        listId: session.listId,
        status: PendingSessionCodeStatus.queued,
        note:
            'Could not load the class list (unstable connection). Will retry.',
        invalidMarkedAt: null,
      );
    }

    final withMeta = entry.copyWith(
      sessionId: session.id,
      listId: list.id,
      lecturerName: list.whoTaught,
      classTime: list.time,
      classLocation: list.room,
      invalidMarkedAt: null,
    );

    final student = AttendanceStore.findStudentByReg(entry.registrationNumber);
    if (student == null) {
      return withMeta.copyWith(
        status: PendingSessionCodeStatus.needsRegistration,
        note: 'Student not on roster yet.',
      );
    }
    if (AttendanceStore.isPresentForSession(session.id, student.id)) {
      return null;
    }

    final course =
        AttendanceStore.signedInCourseForStudentOnList(list.id, student.id);
    if (course == null || course.trim().isEmpty) {
      return withMeta.copyWith(
        status: PendingSessionCodeStatus.needsRegistration,
        note:
            'Sign into this class list (pick your course) so this check-in can finish.',
      );
    }

    final withinTime = isTimestampWithinSessionBounds(session, entry.capturedAt);
    final withinRadius =
        isPositionWithinSession(session, entry.latitude, entry.longitude);
    if (!withinTime || !withinRadius) {
      return withMeta.copyWith(
        status: PendingSessionCodeStatus.invalidOrExpired,
        note: withinTime
            ? 'Outside class location radius at capture time.'
            : 'Captured outside session time window.',
        invalidMarkedAt: entry.invalidMarkedAt ?? now,
      );
    }

    final record = AttendanceRecord(
      id: '${session.id}_${student.id}',
      sessionId: session.id,
      studentId: student.id,
      course: course.trim(),
      timestamp: entry.capturedAt,
      latitude: entry.latitude,
      longitude: entry.longitude,
      selfieStoragePath: null,
      verified: true,
      present: true,
      deviceId: entry.deviceId,
    );
    final outcome = await AttendanceRepository.instance
        .submitStudentCheckInWithOfflineSupport(record);
    switch (outcome) {
      case StudentOfflineCheckInOutcome.success:
      case StudentOfflineCheckInOutcome.duplicate:
        return null;
      case StudentOfflineCheckInOutcome.queuedOffline:
        return withMeta.copyWith(
          status: PendingSessionCodeStatus.queued,
          note:
              'Attendance saved on this device; will upload when the connection is stable.',
        );
      case StudentOfflineCheckInOutcome.deviceBlocked:
        return withMeta.copyWith(
          status: PendingSessionCodeStatus.deviceBlocked,
          note: 'Another student already used this device for this session.',
        );
    }
  }
}
