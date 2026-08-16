import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/connectivity/app_connectivity.dart';
import '../../../core/notifications/notification_maintenance_coordinator.dart';
import '../check_in_outcome.dart';
import '../models/attendance_models.dart';
import 'attendance_repository.dart';
import 'pending_check_in_queue.dart';
import 'pending_retention.dart';
import 'pending_list_create_queue.dart';
import 'pending_list_create_sync.dart';
import 'pending_session_code_queue.dart';
import 'pending_session_code_sync.dart';
import 'pending_session_create_queue.dart';
import 'pending_session_create_sync.dart';
import '../../campus_presence/data/pending_campus_presence_queue.dart';
import '../../campus_presence/data/pending_campus_presence_sync.dart';

/// Totals for locally queued attendance work not yet on the server.
class PendingOfflineWorkCounts {
  const PendingOfflineWorkCounts({
    required this.checkIns,
    required this.sessionCodes,
    required this.sessionCreates,
    required this.listCreates,
    required this.campusPresence,
  });

  final int checkIns;
  final int sessionCodes;
  final int sessionCreates;
  final int listCreates;
  final int campusPresence;

  int get total =>
      checkIns + sessionCodes + sessionCreates + listCreates + campusPresence;

  String get summaryLabel {
    if (total == 1) return '1 pending item';
    return '$total pending items';
  }
}

/// Drains locally queued check-ins after connectivity returns or on app resume.
///
/// Re-validates each entry against the **stored** capture time and coordinates
/// and the session loaded into [AttendanceStore] (after [loadAll]).
class AttendanceOfflineSync {
  AttendanceOfflineSync._();

  static bool _drainAgain = false;
  static Future<void>? _drainTail;

  static const Duration _drainReachabilityTimeout = Duration(seconds: 3);

  /// Uploads pending work in order, then one [loadAll] so the store is not wiped
  /// mid-drain (which caused present/absent to flip when sessions started offline).
  static Future<void> drainAllInOrder() async {
    await _withDrainLock(() async {
      await _drainAllInOrderBodyWithoutLoadAll();
      final counts = await countPendingWork();
      if (counts.checkIns > 0 || counts.sessionCodes > 0) {
        await _runStep(
          '_refreshAfterSessionValidation',
          _refreshAfterSessionValidation,
        );
        return;
      }
      // Staff rolls still need a full refresh while students await verification.
      final studentAwaitingVerification =
          AttendanceRepository.isStudentScopedUser() &&
              AttendanceStore.attendanceRecords
                  .any((r) => r.present && !r.verified);
      if (studentAwaitingVerification) {
        await _runStep(
          '_refreshAfterSessionValidation',
          _refreshAfterSessionValidation,
        );
        return;
      }
      if (await _onlineForDrain()) {
        await _runStep('loadAllAfterDrain', _loadAllFromRemote);
      }
    });
  }

  /// Session code validation first, then check-ins — updates records before other sync.
  static Future<void> drainSessionValidationFirst() async {
    await _withDrainLock(_drainSessionValidationFirstBody);
  }

  /// Bounded upload pass for background / tab blur — skips sign-in sweeps and loadAll.
  static Future<void> drainUrgentUploadsOnly({
    Duration timeBudget = const Duration(seconds: 45),
  }) async {
    await _withDrainLock(() => _drainUrgentUploadsOnlyBody(timeBudget));
  }

  static Future<void> _drainUrgentUploadsOnlyBody(Duration timeBudget) async {
    if (!AppConnectivity.instance.hasNetworkInterface) return;
    final deadline = DateTime.now().add(timeBudget);
    bool withinBudget() => !DateTime.now().isAfter(deadline);

    Future<void> step(String label, Future<void> Function() fn) async {
      if (!withinBudget()) return;
      await _runStep(label, fn);
    }

    // Check-ins first — students waiting on upload should not wait for list/session drains.
    await step(
      'AttendanceRepository.syncUnuploadedSignIns',
      AttendanceRepository.instance.syncUnuploadedSignIns,
    );
    if (!withinBudget()) return;
    await step('_drainCheckInsWithoutReload', _drainCheckInsWithoutReload);
    if (!withinBudget()) return;
    await step('PendingListCreateSync.drain', PendingListCreateSync.drain);
    if (!withinBudget()) return;
    await step(
      'PendingSessionCreateSync.drainUrgent',
      PendingSessionCreateSync.drainUrgent,
    );
    if (!withinBudget()) return;
    await step(
      'PendingSessionCodeSync.drainUrgent',
      PendingSessionCodeSync.drainUrgent,
    );
  }

  /// Fast path when connectivity returns: validate pending sessions first.
  static Future<void> drainCheckInsPromptly() async {
    await drainSessionValidationFirst();
  }

  /// Upload-only pass for the active check-in hot path — skips list/session drains.
  static Future<void> drainCheckInUploadsOnly() async {
    await _withDrainLock(() async {
      if (!AppConnectivity.instance.hasNetworkInterface) return;
      await _runStep(
        'AttendanceRepository.syncUnuploadedSignIns',
        AttendanceRepository.instance.syncUnuploadedSignIns,
      );
      await _runStep(
        '_drainCheckInsWithoutReload',
        _drainCheckInsWithoutReload,
      );
    });
  }

  static Future<void> _withDrainLock(Future<void> Function() body) async {
    final previous = _drainTail;
    final gate = Completer<void>();
    _drainTail = gate.future;

    if (previous != null) {
      await previous;
    }

    try {
      do {
        _drainAgain = false;
        await body();
      } while (_drainAgain);
    } finally {
      gate.complete();
    }
  }

  static Future<bool> _onlineForDrain() async {
    if (!AppConnectivity.instance.hasNetworkInterface) return false;
    return AppConnectivity.instance.ensureReachable(
      timeout: _drainReachabilityTimeout,
    );
  }

  static Future<void> _loadAllFromRemote() async {
    await AttendanceRepository.instance.loadAll(
      force: true,
      scopeToLecturerUid: AttendanceRepository.currentLecturerLoadScopeUid(),
    );
  }

  /// Pending session creates → session-code validation → GPS check-ins → UI refresh.
  static Future<void> _drainSessionValidationFirstBody() async {
    if (!AppConnectivity.instance.hasNetworkInterface) {
      await _runStep('purgeExpiredPendingOnly', purgeExpiredPendingOnly);
      return;
    }
    PendingSessionCodeSync.refreshSessionPublishWatchesFromQueue();
    await _runStep(
      'PendingListCreateSync.drain',
      PendingListCreateSync.drain,
    );
    await _runStep(
      'PendingSessionCreateSync.drainUrgent',
      PendingSessionCreateSync.drainUrgent,
    );
    await _runStep(
      'PendingSessionCodeSync.drainUrgent',
      PendingSessionCodeSync.drainUrgent,
    );
    await _runStep('purgeExpiredPendingOnly', purgeExpiredPendingOnly);
    // Upload/compare on any network — do not gate on API reachability probe.
    // Captive portals and slow probes left queues stuck at Pending while urgent
    // drains at the top had already succeeded.
    await _runStep(
      'AttendanceRepository.syncUnuploadedSignIns',
      AttendanceRepository.instance.syncUnuploadedSignIns,
    );
    await _runStep(
      '_drainSessionCodesWithRetry',
      _drainSessionCodesWithRetry,
    );
    await _runStep(
      '_drainCheckInsWithoutReload',
      _drainCheckInsWithoutReload,
    );
    await _runStep(
      '_refreshAfterSessionValidation',
      _refreshAfterSessionValidation,
    );
    if (await _onlineForDrain()) {
      await _runStep(
        'correctMetadataMatchedAbsentRollForSignedInLists',
        AttendanceRepository.instance
            .correctMetadataMatchedAbsentRollForSignedInLists,
      );
    }
  }

  /// Re-runs session-code upload after session creates; stops when queue drains or stalls.
  static Future<void> _drainSessionCodesWithRetry() async {
    final initial = await PendingSessionCodeQueue.loadAll();
    if (initial.isEmpty) return;
    final allUploaded =
        initial.every((e) => e.hasLocalUploadEvidence);
    final maxPasses = allUploaded ? 3 : 4;
    for (var pass = 0; pass < maxPasses; pass++) {
      if (pass > 0 && AppConnectivity.instance.hasNetworkInterface) {
        await PendingListCreateSync.drain();
        await PendingSessionCreateSync.drainUrgent();
        await PendingSessionCodeSync.drainUrgent();
        await Future<void>.delayed(Duration(milliseconds: 350 * pass));
      }
      final before = (await PendingSessionCodeQueue.loadAll()).length;
      if (before == 0) return;
      if (AppConnectivity.instance.hasNetworkInterface) {
        final snapshot = await PendingSessionCodeQueue.loadAll();
        if (snapshot.any((e) => e.hasLocalUploadEvidence)) {
          await AttendanceRepository.instance.prefetchSessionsForPendingCodes();
        }
      }
      await PendingSessionCodeSync.drainUrgent();
      final after = (await PendingSessionCodeQueue.loadAll()).length;
      if (after == 0) return;
      if (after < before) continue;
      if (allUploaded) return;
    }
  }

  static Future<void> _refreshAfterSessionValidation() async {
    AttendanceRepository.instance.notifyAttendanceStoreUpdated();
    if (AttendanceRepository.isStudentScopedUser()) {
      unawaited(
        AttendanceRepository.instance.loadStudentAttendanceForProfile(
          force: false,
        ),
      );
    }
  }

  static Future<void> _drainAllInOrderBodyWithoutLoadAll() async {
    await _drainSessionValidationFirstBody();
    if (!await _onlineForDrain()) return;

    if (await _onlineForDrain()) {
      await _runStep(
        'reconcileDeletedListsAgainstRemote',
        () => AttendanceRepository.instance
            .reconcileDeletedListsAgainstRemote(force: true),
      );
    }
    await _runStep(
      'PendingCampusPresenceSync.drain',
      PendingCampusPresenceSync.drain,
    );
    await _runStep('PendingListCreateSync.drain', PendingListCreateSync.drain);
    final counts = await countPendingWork();
    if (counts.total == 0) {
      await _runStep(
        'correctMetadataMatchedAbsentRollForSignedInLists',
        AttendanceRepository.instance
            .correctMetadataMatchedAbsentRollForSignedInLists,
      );
      await _runStep(
        'finalizeGraceExpiredSessions',
        AttendanceRepository.instance.finalizeGraceExpiredSessions,
      );
    }
    await _runStep(
      'NotificationMaintenanceCoordinator.onAttendanceStoreUpdated',
      NotificationMaintenanceCoordinator.onAttendanceStoreUpdated,
    );
  }

  static Future<void> _runStep(
    String label,
    Future<void> Function() step,
  ) async {
    try {
      await step();
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('AttendanceOfflineSync.$label failed: $e');
        debugPrint('$st');
      }
    }
  }

  /// Removes expired queue rows and marks unverified check-ins absent after 7 days.
  static Future<void> purgeExpiredPendingOnly() async {
    final now = DateTime.now();
    final checkIns = await PendingCheckInQueue.loadAll();
    final keptCheckIns = <PendingCheckInEntry>[];
    for (final e in checkIns) {
      if (PendingRetention.isExpired(e.pendingSince, now)) {
        await _markUnverifiedCheckInAbsent(e);
        continue;
      }
      keptCheckIns.add(e);
    }
    if (keptCheckIns.length != checkIns.length) {
      await PendingCheckInQueue.saveAll(keptCheckIns);
    }

    final codes = await PendingSessionCodeQueue.loadAll();
    await PendingSessionCodeQueue.mutate((codes) async {
      final keptCodes = <PendingSessionCodeEntry>[];
      for (final e in codes) {
        if (PendingSessionCodeSync.dropVerifiedMismatchInvalid(e)) {
          final marked = e.invalidMarkedAt ?? e.pendingSince;
          if (PendingRetention.isExpired(marked, now)) {
            PendingSessionCodeSync.discardLocalAttendanceSideEffects(e);
            continue;
          }
          keptCodes.add(e);
          continue;
        }
        if (PendingRetention.isExpired(e.pendingSince, now)) {
          PendingSessionCodeSync.discardLocalAttendanceSideEffects(e);
          continue;
        }
        keptCodes.add(e);
      }
      return keptCodes;
    });

    final creates = await PendingSessionCreateQueue.loadAll();
    final keptCreates = creates
        .where((e) => !PendingRetention.isExpired(e.enqueuedAt, now))
        .toList();
    if (keptCreates.length != creates.length) {
      await PendingSessionCreateQueue.saveAll(keptCreates);
    }

    final listCreates = await PendingListCreateQueue.loadAll();
    final keptLists = listCreates
        .where((e) => !PendingRetention.isExpired(e.enqueuedAt, now))
        .toList();
    if (keptLists.length != listCreates.length) {
      await PendingListCreateQueue.saveAll(keptLists);
    }

    final campusPresence = await PendingCampusPresenceQueue.loadAll();
    final keptCampusPresence = campusPresence
        .where((e) => !PendingRetention.isExpired(e.pendingSince, now))
        .toList();
    if (keptCampusPresence.length != campusPresence.length) {
      await PendingCampusPresenceQueue.saveAll(keptCampusPresence);
    }
  }

  /// Best-effort GPS check-in queue (no [loadAll] — caller runs after full drain).
  static Future<void> drain() => drainAllInOrder();

  /// Counts rows waiting to upload from local offline queues.
  static Future<PendingOfflineWorkCounts> countPendingWork() async {
    final checkIns = (await PendingCheckInQueue.loadAll()).length;
    final sessionCodes = (await PendingSessionCodeQueue.loadAll()).length;
    final sessionCreates = (await PendingSessionCreateQueue.loadAll()).length;
    final listCreates = (await PendingListCreateQueue.loadAll()).length;
    final campusPresence = (await PendingCampusPresenceQueue.loadAll()).length;
    return PendingOfflineWorkCounts(
      checkIns: checkIns,
      sessionCodes: sessionCodes,
      sessionCreates: sessionCreates,
      listCreates: listCreates,
      campusPresence: campusPresence,
    );
  }

  static Future<void> _drainCheckInsWithoutReload() async {
    try {
      final pending = await PendingCheckInQueue.loadAll();
      if (pending.isEmpty) {
        return;
      }

      if (AppConnectivity.instance.hasNetworkInterface) {
        await AttendanceRepository.instance.prepareOfflineCheckInDrain();
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

      var droppedDuplicate = 0;
      var droppedDeviceBlocked = 0;
      var droppedExpiredSession = 0;
      final keep = <PendingCheckInEntry>[];
      final uploadedPairs = <({String sessionId, String studentId})>[];
      final repo = AttendanceRepository.instance;

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
        final d = e.deviceId.trim();
        if (d.isNotEmpty &&
            await repo.isDeviceBlockedForStudentSession(
              sessionId: e.sessionId,
              studentId: e.studentId,
              deviceId: d,
              sessionCodeRaw: session.sessionCode,
            )) {
          droppedDeviceBlocked++;
          await repo.clearLocalUnverifiedPresentForCheckIn(e.id, force: true);
          continue;
        }

        final sessionCodeRaw =
            normalizeSessionCodeInput(session.sessionCode);
        final canonicalId = repo.canonicalStudentIdForUpload(e.studentId);
        final pendingEntry = canonicalId == e.studentId.trim()
            ? e
            : PendingCheckInEntry(
                id: attendanceRecordIdForSessionStudent(e.sessionId, canonicalId),
                sessionId: e.sessionId,
                studentId: canonicalId,
                listId: e.listId,
                course: e.course,
                capturedAt: e.capturedAt,
                latitude: e.latitude,
                longitude: e.longitude,
                deviceId: e.deviceId,
                pendingSince: e.pendingSince,
              );

        if (AttendanceStore.hasCheckedIn(e.sessionId, e.studentId)) {
          final existing = AttendanceStore.attendanceRecordForSessionStudent(
            e.sessionId,
            e.studentId,
          );
          if (existing != null &&
              existing.present &&
              existing.verified &&
              await repo.isCheckInAttemptAcceptedForSessionStudent(
                sessionId: e.sessionId,
                studentId: e.studentId,
              )) {
            keep.add(
              e.copyWith(status: PendingCheckInQueueStatus.approved),
            );
            droppedDuplicate++;
            continue;
          }
        }

        if (e.hasLocalUploadEvidence) {
          final approved = await repo.pendingCheckInIsApproved(
            entry: pendingEntry,
            session: session,
          );
          keep.add(
            pendingEntry.copyWith(
              status: approved
                  ? PendingCheckInQueueStatus.approved
                  : PendingCheckInQueueStatus.queued,
              uploadedAt: e.uploadedAt ?? pendingEntry.uploadedAt,
            ),
          );
          continue;
        }

        final outcome = await repo.submitStudentCheckInWithOfflineSupport(
          pendingEntry.toAttendanceRecord(),
          listIdOverride: e.listId,
          sessionCodeRaw: sessionCodeRaw,
        );
        switch (outcome) {
          case StudentOfflineCheckInOutcome.success:
          case StudentOfflineCheckInOutcome.duplicate:
            final approved = await repo.pendingCheckInIsApproved(
              entry: pendingEntry,
              session: session,
            );
            if (approved) {
              uploadedPairs.add((sessionId: e.sessionId, studentId: e.studentId));
              keep.add(
                pendingEntry.copyWith(status: PendingCheckInQueueStatus.approved),
              );
            } else {
              keep.add(
                pendingEntry.copyWith(status: PendingCheckInQueueStatus.queued),
              );
            }
            break;
          case StudentOfflineCheckInOutcome.submittedPendingVerification:
            final uploaded = await repo.pendingCheckInHasServerEvidence(
              entry: pendingEntry,
              session: session,
            );
            final approved = await repo.pendingCheckInIsApproved(
              entry: pendingEntry,
              session: session,
            );
            if (uploaded) {
              uploadedPairs.add((sessionId: e.sessionId, studentId: e.studentId));
              await PendingCheckInQueue.markUploaded(pendingEntry.id);
            }
            final uploadStamp = e.uploadedAt ?? pendingEntry.uploadedAt;
            keep.add(
              pendingEntry.copyWith(
                status: approved
                    ? PendingCheckInQueueStatus.approved
                    : PendingCheckInQueueStatus.queued,
                uploadedAt: uploaded || uploadStamp != null
                    ? (uploadStamp ?? DateTime.now())
                    : null,
              ),
            );
            break;
          case StudentOfflineCheckInOutcome.queuedOffline:
            keep.add(pendingEntry);
            break;
          case StudentOfflineCheckInOutcome.sessionMismatch:
          case StudentOfflineCheckInOutcome.rejectedVerification:
            if (AttendanceRepository.pendingCheckInMatchesSessionForCorrection(
              e,
              session,
            )) {
              final local = e.toAttendanceRecord();
              AttendanceStore.updateAttendanceRecord(
                AttendanceRecord(
                  id: local.id,
                  sessionId: local.sessionId,
                  studentId: local.studentId,
                  course: local.course,
                  timestamp: local.timestamp,
                  latitude: local.latitude,
                  longitude: local.longitude,
                  verified: true,
                  present: true,
                  deviceId: local.deviceId,
                ),
              );
              repo.notifyAttendanceStoreUpdated();
            }
            keep.add(e);
            break;
          case StudentOfflineCheckInOutcome.deviceBlocked:
            droppedDeviceBlocked++;
            await repo.clearLocalUnverifiedPresentForCheckIn(e.id, force: true);
            break;
        }
      }
      await PendingCheckInQueue.saveAll(keep);
      if (uploadedPairs.isNotEmpty) {
        await Future.wait(
          uploadedPairs.map(
            (p) => repo.quickVerifyStudentCheckIn(
              sessionId: p.sessionId,
              studentId: p.studentId,
            ),
          ),
        );
        repo.notifyAttendanceStoreUpdated();
      }
      if (droppedDuplicate > 0 ||
          droppedDeviceBlocked > 0 ||
          droppedExpired > 0 ||
          droppedExpiredSession > 0) {
        debugPrint(
          'AttendanceOfflineSync: dropped '
          '$droppedDuplicate duplicate, '
          '$droppedDeviceBlocked device-blocked, '
          '$droppedExpired+$droppedExpiredSession expired pending item(s).',
        );
      }
    } catch (_) {
      // Leave queue intact; next drain will retry.
    }
  }

  static Future<void> _markUnverifiedCheckInAbsent(PendingCheckInEntry e) async {
    AttendanceStore.removeAttendanceRecordById(e.id);
    final session = AttendanceStore.sessionById(e.sessionId);
    if (session == null) return;
    var course = e.course.trim();
    if (course.isEmpty) {
      course = AttendanceStore.courseForStudentOnList(e.listId, e.studentId);
    }
    if (course.isEmpty) course = '—';
    final absent = AttendanceRecord(
      id: e.id,
      sessionId: e.sessionId,
      studentId: e.studentId,
      course: course,
      timestamp: DateTime.now(),
      latitude: 0,
      longitude: 0,
      verified: false,
      present: false,
    );
    if (!AttendanceStore.hasCheckedIn(e.sessionId, e.studentId)) {
      AttendanceStore.addAttendanceRecord(absent);
    }
  }
}
