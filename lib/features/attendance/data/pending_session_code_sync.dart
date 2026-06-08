import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../check_in_outcome.dart';
import '../../../core/device/device_student_registration_lock.dart';
import '../check_in_rejection.dart';
import '../check_in_validation.dart'
    show
        isPositionWithinSession,
        isTimestampWithinSessionBounds,
        resolveCourseForStudentCheckIn,
        verifyLinkedSessionCheckIn;
import '../../../core/connectivity/app_connectivity.dart';
import '../../../core/firebase/firestore_collections.dart';
import '../../../core/firebase/u_panel_firestore.dart';
import 'package:flutter/foundation.dart';
import '../models/attendance_models.dart';
import 'attendance_repository.dart';
import 'pending_retention.dart';
import 'pending_session_code_queue.dart';
import 'pending_session_code_claim_upload.dart';

class PendingSessionCodeSync {
  PendingSessionCodeSync._();

  static Future<void>? _drainTail;
  static final Set<String> _watchedPublishCodes = {};
  static final List<StreamSubscription<QuerySnapshot<Map<String, dynamic>>>>
      _sessionPublishSubs = [];

  static Future<void> _withDrainLock(Future<void> Function() body) async {
    final prior = _drainTail;
    final gate = Completer<void>();
    _drainTail = gate.future;
    if (prior != null) {
      await prior;
    }
    try {
      await body();
    } finally {
      gate.complete();
    }
  }

  /// Removes any optimistic local present row tied to a dropped code queue row.
  static void discardLocalAttendanceSideEffects(PendingSessionCodeEntry entry) {
    final sid = entry.sessionId?.trim();
    if (sid == null || sid.isEmpty) return;
    final student = AttendanceStore.findStudentByReg(entry.registrationNumber);
    if (student == null) return;
    unawaited(
      AttendanceRepository.instance.clearLocalUnverifiedPresentForCheckIn(
        attendanceRecordIdForSessionStudent(sid, student.id),
        force: true,
      ),
    );
  }

  static void _dropExpiredEntry(PendingSessionCodeEntry entry) {
    discardLocalAttendanceSideEffects(entry);
  }

  /// Removed from queue: session code verified but capture time/location invalid.
  static const _rejectVerifiedMismatch = 1;

  /// Removed from queue: check-in submitted or duplicate.
  static const _removeSubmitted = 2;

  /// Removed from queue: session metadata uploaded to server (no local copy).
  static const _removeUploadedMetadata = 3;

  /// Result of [processOnCreate] — whether to persist locally.
  static Future<({bool discardLocal, PendingSessionCodeEntry? keepLocal})>
      processOnCreate(PendingSessionCodeEntry entry) async {
    final result = await _tryProcess(entry, DateTime.now());
    if (result is int) {
      switch (result) {
        case _removeSubmitted:
        case _removeUploadedMetadata:
        case _rejectVerifiedMismatch:
          return (discardLocal: true, keepLocal: null);
        default:
          return (discardLocal: false, keepLocal: entry);
      }
    }
    return (discardLocal: false, keepLocal: result as PendingSessionCodeEntry);
  }

  /// Fast path on reconnect or right after create: skip reachability probe.
  static Future<void> drainUrgent() async {
    await _withDrainLock(() => _drainBodyWithoutReload(urgent: true));
  }

  /// Live Firestore watch — retries as soon as the lecturer session doc appears.
  static void ensureWatchingSessionPublishForCodes(Iterable<String> rawCodes) {
    final db = tryUPanelFirestore();
    if (db == null) return;
    for (final raw in rawCodes) {
      final code = normalizeSessionCodeInput(raw);
      if (!isValidJoinCodeFormat(code) || !_watchedPublishCodes.add(code)) {
        continue;
      }
      final sub = db
          .collection(FirestoreCollections.attendanceSessions)
          .where('sessionCode', isEqualTo: code)
          .where('status', isEqualTo: SessionStatus.active.name)
          .limit(4)
          .snapshots()
          .listen(
        (snap) {
          if (snap.docs.isEmpty) return;
          unawaited(drainUrgent());
        },
        onError: (Object e, StackTrace st) {
          if (kDebugMode) {
            debugPrint('PendingSessionCodeSync session watch $code: $e');
          }
        },
      );
      _sessionPublishSubs.add(sub);
    }
  }

  static void refreshSessionPublishWatchesFromQueue() {
    unawaited(() async {
      final codes = (await PendingSessionCodeQueue.loadAll())
          .map((e) => e.sessionCodeRaw)
          .where((c) => c.trim().isNotEmpty);
      ensureWatchingSessionPublishForCodes(codes);
    }());
  }

  static Future<void> stopSessionPublishWatches() async {
    for (final sub in _sessionPublishSubs) {
      await sub.cancel();
    }
    _sessionPublishSubs.clear();
    _watchedPublishCodes.clear();
  }

  /// Always use the original capture time — never substitute sync time.
  static DateTime _validationTimestampForPendingCode(
    PendingSessionCodeEntry entry,
  ) =>
      entry.capturedAt;

  static Future<void> drain() async {
    await _withDrainLock(_drainBody);
  }

  static Future<void> _drainBody() async {
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
        if (_dropVerifiedMismatchInvalid(entry)) {
          _dropExpiredEntry(entry);
          invalidRemovedCount++;
          continue;
        }
        if (PendingRetention.isExpired(entry.pendingSince, now)) {
          _dropExpiredEntry(entry);
          invalidRemovedCount++;
          continue;
        }
        keep.add(entry);
      }

      if (!AppConnectivity.instance.hasNetworkInterface ||
          !await AppConnectivity.instance.ensureReachable()) {
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
      refreshSessionPublishWatchesFromQueue();
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
  }

  /// Session-code queue only (no [loadAll]). Use [AttendanceOfflineSync.drainAllInOrder].
  static Future<void> drainWithoutReload() async {
    await _withDrainLock(() => _drainBodyWithoutReload(urgent: false));
  }

  static Future<void> _drainBodyWithoutReload({required bool urgent}) async {
      final all = await PendingSessionCodeQueue.loadAll();
      if (all.isEmpty) return;
      if (!AppConnectivity.instance.hasNetworkInterface) return;
      if (!urgent &&
          !await AppConnectivity.instance.ensureReachable(
            timeout: const Duration(seconds: 3),
          )) {
        return;
      }

      final now = DateTime.now();
      final keep = <PendingSessionCodeEntry>[];
      for (final entry in all) {
        if (_dropVerifiedMismatchInvalid(entry)) {
          _dropExpiredEntry(entry);
          continue;
        }
        if (PendingRetention.isExpired(entry.pendingSince, now)) {
          _dropExpiredEntry(entry);
          continue;
        }
        keep.add(entry);
      }
      if (keep.isEmpty) {
        await PendingSessionCodeQueue.saveAll(const []);
        return;
      }
      final processed = await _processEntriesOnline(keep, now);
      await PendingSessionCodeQueue.saveAll(processed.remaining);
      refreshSessionPublishWatchesFromQueue();
  }

  /// Legacy rows: code was verified but time/location failed — drop immediately.
  static bool dropVerifiedMismatchInvalid(PendingSessionCodeEntry entry) {
    if (entry.status != PendingSessionCodeStatus.invalidOrExpired) {
      return false;
    }
    return entry.sessionId != null && entry.sessionId!.trim().isNotEmpty;
  }

  static bool _dropVerifiedMismatchInvalid(PendingSessionCodeEntry entry) =>
      dropVerifiedMismatchInvalid(entry);

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
      final result = await _tryProcess(entry, now);
      if (result is int) {
        if (result == _removeSubmitted) {
          autoSubmittedCount++;
          AttendanceRepository.instance.notifyAttendanceStoreUpdated();
        } else if (result == _rejectVerifiedMismatch) {
          invalidRemovedCount++;
        }
        continue;
      }
      final updated = result as PendingSessionCodeEntry;
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

  static AttendanceSession? _sessionLinkedInStore(PendingSessionCodeEntry entry) {
    final normalizedCode = normalizeSessionCodeInput(entry.sessionCodeRaw);
    final hint = entry.sessionId?.trim();
    if (hint != null && hint.isNotEmpty) {
      final byId = AttendanceStore.sessionById(hint);
      if (byId != null &&
          normalizeSessionCodeInput(byId.sessionCode) == normalizedCode) {
        return byId;
      }
    }
    final byCode = AttendanceRepository.instance.validateSessionCode(
      entry.sessionCodeRaw,
    );
    if (byCode == null) return null;
    if (hint != null &&
        hint.isNotEmpty &&
        byCode.id != hint) {
      return null;
    }
    return byCode;
  }

  static Future<Object> _completeLinkedPendingEntry({
    required PendingSessionCodeEntry entry,
    required AttendanceSession session,
    required DateTime now,
    required StudentRecord? studentForGuard,
  }) async {
    final repo = AttendanceRepository.instance;

    var list = AttendanceStore.listById(session.listId);
    list ??= await repo.resolveListById(session.listId);
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

    var student = studentForGuard ??
        await repo.resolveStudentForRegistration(entry.registrationNumber);
    if (student == null) {
      return withMeta.copyWith(
        status: PendingSessionCodeStatus.needsRegistration,
        note: 'Student not on roster yet.',
      );
    }
    if (!AttendanceStore.hasStudentSignedIntoList(list.id, student.id)) {
      final enroll = await repo.ensureStudentEnrolledOnList(
        list: list,
        student: student,
      );
      switch (enroll) {
        case StudentListEnrollOutcome.noCourses:
          return withMeta.copyWith(
            status: PendingSessionCodeStatus.needsRegistration,
            note:
                'This class list has no courses. Ask staff to add courses, then retry.',
          );
        case StudentListEnrollOutcome.needsCourseChoice:
          return withMeta.copyWith(
            status: PendingSessionCodeStatus.needsRegistration,
            note:
                'Open Attendance, enter your session code, and choose a course to join this list.',
          );
        case StudentListEnrollOutcome.deviceBlocked:
          return withMeta.copyWith(
            status: PendingSessionCodeStatus.deviceBlocked,
            note: DeviceStudentRegistrationLock.blockMessage,
          );
        case StudentListEnrollOutcome.alreadyEnrolled:
        case StudentListEnrollOutcome.enrolled:
          break;
      }
    }
    if (AttendanceStore.isPresentForSession(session.id, student.id)) {
      return _removeSubmitted;
    }

    final boundsTime = _validationTimestampForPendingCode(entry);
    final course = resolveCourseForStudentCheckIn(list, student.id);

    final record = AttendanceRecord(
      id: '${session.id}_${student.id}',
      sessionId: session.id,
      studentId: student.id,
      course: course,
      timestamp: boundsTime,
      latitude: entry.latitude,
      longitude: entry.longitude,
      verified: true,
      present: true,
      deviceId: entry.deviceId,
    );
    final outcome = await repo.submitStudentCheckInWithOfflineSupport(
      record,
      listIdOverride: list.id,
      sessionCodeRaw: entry.sessionCodeRaw,
    );
    switch (outcome) {
      case StudentOfflineCheckInOutcome.success:
      case StudentOfflineCheckInOutcome.submittedPendingVerification:
      case StudentOfflineCheckInOutcome.duplicate:
        if (!AttendanceStore.hasSignedIn(list.id, student.id, course)) {
          unawaited(
            repo.ensureSignInAndBackfillPastAbsents(
              listId: list.id,
              studentId: student.id,
              course: course,
            ),
          );
        }
        if (outcome == StudentOfflineCheckInOutcome.submittedPendingVerification) {
          unawaited(
            repo.awaitOfficialRecordFromFirebase(
              sessionId: session.id,
              studentId: student.id,
              timeout: const Duration(seconds: 12),
            ),
          );
        }
        return _removeSubmitted;
      case StudentOfflineCheckInOutcome.sessionMismatch:
      case StudentOfflineCheckInOutcome.rejectedVerification:
        return _rejectVerifiedMismatch;
      case StudentOfflineCheckInOutcome.queuedOffline:
        return withMeta.copyWith(
          status: PendingSessionCodeStatus.queued,
          note:
              'Attendance saved on this device; will upload when the connection is stable.',
        );
      case StudentOfflineCheckInOutcome.deviceBlocked:
        return withMeta.copyWith(
          status: PendingSessionCodeStatus.deviceBlocked,
          note: deviceAlreadyUsedUserMessage,
        );
    }
  }

  static Future<Object> _tryProcess(
    PendingSessionCodeEntry entry,
    DateTime now,
  ) async {
    if (entry.status == PendingSessionCodeStatus.deviceBlocked) {
      return entry;
    }

    final repo = AttendanceRepository.instance;
    final studentForGuard =
        await repo.resolveStudentForRegistration(entry.registrationNumber);
    if (studentForGuard != null) {
      final block = await PendingSessionCodeClaimUpload.deviceBlockReason(
        entry: entry,
        studentId: studentForGuard.id,
      );
      if (block != null) {
        return entry.copyWith(
          status: PendingSessionCodeStatus.deviceBlocked,
          note: block,
        );
      }
    }

    final linked = _sessionLinkedInStore(entry);
    if (linked != null) {
      final verification = verifyLinkedSessionCheckIn(
        session: linked,
        at: _validationTimestampForPendingCode(entry),
        latitude: entry.latitude,
        longitude: entry.longitude,
      );
      if (verification.passed) {
        return _completeLinkedPendingEntry(
          entry: entry,
          session: linked,
          now: now,
          studentForGuard: studentForGuard,
        );
      }
      if (!verification.passed && linked.isOpenForCheckIn) {
        return _rejectVerifiedMismatch;
      }
    }

    var session = await repo.resolvePublishedLecturerSessionForPendingClaim(
      sessionCodeRaw: entry.sessionCodeRaw,
      capturedAt: entry.capturedAt,
      sessionIdHint: entry.sessionId,
    );
    if (session == null) {
      final localOnly = await repo.resolveSessionForPendingCodeEntry(
        sessionCodeRaw: entry.sessionCodeRaw,
        capturedAt: entry.capturedAt,
        sessionIdHint: entry.sessionId,
      );
      if (localOnly != null &&
          !await repo.isLecturerSessionPublishedOnServer(localOnly.id)) {
        final student = studentForGuard ??
            await repo.resolveStudentForRegistration(entry.registrationNumber);
        if (student != null) {
          final metadataOnServer =
              await PendingSessionCodeClaimUpload.isClaimOnServer(
            entry: entry,
            studentId: student.id,
          );
          if (!metadataOnServer) {
            final uploaded =
                await PendingSessionCodeClaimUpload.uploadForEntryWithStudent(
              entry: entry,
              studentId: student.id,
            );
            if (uploaded) {
              return _removeUploadedMetadata;
            }
          } else {
            return _removeUploadedMetadata;
          }
        }
        return entry.copyWith(
          sessionId: localOnly.id,
          listId: localOnly.listId,
          status: PendingSessionCodeStatus.queued,
          note:
              'Your check-in is saved — waiting for lecturer session to upload (up to ${PendingRetention.unverifiedPending.inDays} days).',
          invalidMarkedAt: null,
        );
      }
    }
    if (session == null) {
      final student = studentForGuard ??
          await repo.resolveStudentForRegistration(entry.registrationNumber);
      var metadataOnServer = false;
      if (student != null) {
        metadataOnServer = await PendingSessionCodeClaimUpload.isClaimOnServer(
          entry: entry,
          studentId: student.id,
        );
        if (!metadataOnServer) {
          metadataOnServer =
              await PendingSessionCodeClaimUpload.uploadForEntryWithStudent(
            entry: entry,
            studentId: student.id,
          );
        }
        if (metadataOnServer) {
          session = await repo.resolvePublishedLecturerSessionForPendingClaim(
            sessionCodeRaw: entry.sessionCodeRaw,
            capturedAt: entry.capturedAt,
            sessionIdHint: entry.sessionId,
          );
          if (session != null) {
            final verified =
                await PendingSessionCodeClaimUpload
                    .awaitImmediateVerificationWhenBothEndsPresent(
              entry: entry,
              studentId: student.id,
              session: session,
            );
            if (verified) {
              return _removeSubmitted;
            }
            // Both ends on server — run full check-in below.
          } else {
            final refreshed =
                await PendingSessionCodeClaimUpload.tryRefreshLocalFromServerClaim(
              entry: entry,
              studentId: student.id,
            );
            if (refreshed) {
              return _removeSubmitted;
            }
            // Student claim only — wait for lecturer session (up to 7 days).
            return _removeUploadedMetadata;
          }
        }
      }
      if (await repo.serverHasOnlyInactiveSessionForCode(entry.sessionCodeRaw)) {
        final endedSession =
            await repo.resolveLatestSessionByCode(entry.sessionCodeRaw);
        if (endedSession != null &&
            isTimestampWithinSessionBounds(endedSession, entry.capturedAt) &&
            isPositionWithinSession(
              endedSession,
              entry.latitude,
              entry.longitude,
            )) {
          session = endedSession;
        } else {
          return entry.copyWith(
            sessionId: null,
            listId: null,
            status: PendingSessionCodeStatus.invalidOrExpired,
            note:
                'Join code ${normalizeSessionCodeInput(entry.sessionCodeRaw)} matches a session that has already ended. '
                'Ask your lecturer for the code currently on screen.',
            invalidMarkedAt: now,
          );
        }
      }
      if (session == null) {
        return entry.copyWith(
          sessionId: null,
          listId: null,
          status: PendingSessionCodeStatus.queued,
          note: student == null
              ? 'Waiting for student registration before upload can complete.'
              : 'Could not upload session metadata yet — saved on this device. '
                  'Will retry when the connection is stable.',
          invalidMarkedAt: null,
        );
      }
    }

    var list = AttendanceStore.listById(session.listId);
    list ??= await repo.resolveListById(session.listId);
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

    final boundsTime = _validationTimestampForPendingCode(entry);
    final withinTime = isTimestampWithinSessionBounds(session, boundsTime);
    final withinRadius =
        isPositionWithinSession(session, entry.latitude, entry.longitude);
    if (!withinTime || !withinRadius) {
      if (kDebugMode) {
        debugPrint(
          'PendingSessionCodeSync: rejected code ${entry.sessionCodeRaw} — '
          '${withinTime ? "outside radius" : "outside session time"} '
          '(session ${session.id}).',
        );
      }
      if (!session.isOpenForCheckIn) {
        return entry.copyWith(
          sessionId: null,
          listId: null,
          status: PendingSessionCodeStatus.queued,
          note:
              'Waiting for an active session with code ${normalizeSessionCodeInput(entry.sessionCodeRaw)}.',
          invalidMarkedAt: null,
        );
      }
      return _rejectVerifiedMismatch;
    }

    final withMeta = entry.copyWith(
      sessionId: session.id,
      listId: list.id,
      lecturerName: list.whoTaught,
      classTime: list.time,
      classLocation: list.room,
      invalidMarkedAt: null,
    );

    var student = await repo.resolveStudentForRegistration(
      entry.registrationNumber,
    );
    if (student == null) {
      return withMeta.copyWith(
        status: PendingSessionCodeStatus.needsRegistration,
        note: 'Student not on roster yet.',
      );
    }
    if (!AttendanceStore.hasStudentSignedIntoList(list.id, student.id)) {
      final enroll = await repo.ensureStudentEnrolledOnList(
        list: list,
        student: student,
      );
      switch (enroll) {
        case StudentListEnrollOutcome.noCourses:
          return withMeta.copyWith(
            status: PendingSessionCodeStatus.needsRegistration,
            note:
                'This class list has no courses. Ask staff to add courses, then retry.',
          );
        case StudentListEnrollOutcome.needsCourseChoice:
          return withMeta.copyWith(
            status: PendingSessionCodeStatus.needsRegistration,
            note:
                'Open Attendance, enter your session code, and choose a course to join this list.',
          );
        case StudentListEnrollOutcome.deviceBlocked:
          return withMeta.copyWith(
            status: PendingSessionCodeStatus.deviceBlocked,
            note: DeviceStudentRegistrationLock.blockMessage,
          );
        case StudentListEnrollOutcome.alreadyEnrolled:
        case StudentListEnrollOutcome.enrolled:
          break;
      }
    }
    if (AttendanceStore.isPresentForSession(session.id, student.id)) {
      return _removeSubmitted;
    }

    final course = resolveCourseForStudentCheckIn(list, student.id);

    final record = AttendanceRecord(
      id: '${session.id}_${student.id}',
      sessionId: session.id,
      studentId: student.id,
      course: course,
      timestamp: boundsTime,
      latitude: entry.latitude,
      longitude: entry.longitude,
      verified: true,
      present: true,
      deviceId: entry.deviceId,
    );
    final outcome = await repo.submitStudentCheckInWithOfflineSupport(
      record,
      listIdOverride: list.id,
      sessionCodeRaw: entry.sessionCodeRaw,
    );
    switch (outcome) {
      case StudentOfflineCheckInOutcome.success:
      case StudentOfflineCheckInOutcome.submittedPendingVerification:
      case StudentOfflineCheckInOutcome.duplicate:
        if (!AttendanceStore.hasSignedIn(list.id, student.id, course)) {
          unawaited(
            repo.ensureSignInAndBackfillPastAbsents(
              listId: list.id,
              studentId: student.id,
              course: course,
            ),
          );
        }
        if (outcome == StudentOfflineCheckInOutcome.submittedPendingVerification) {
          await repo.awaitOfficialRecordFromFirebase(
            sessionId: session.id,
            studentId: student.id,
            timeout: const Duration(seconds: 12),
          );
        }
        return _removeSubmitted;
      case StudentOfflineCheckInOutcome.sessionMismatch:
      case StudentOfflineCheckInOutcome.rejectedVerification:
        return _rejectVerifiedMismatch;
      case StudentOfflineCheckInOutcome.queuedOffline:
        return withMeta.copyWith(
          status: PendingSessionCodeStatus.queued,
          note:
              'Attendance saved on this device; will upload when the connection is stable.',
        );
      case StudentOfflineCheckInOutcome.deviceBlocked:
        return withMeta.copyWith(
          status: PendingSessionCodeStatus.deviceBlocked,
          note: deviceAlreadyUsedUserMessage,
        );
    }
  }
}
