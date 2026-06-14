import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

import '../check_in_outcome.dart';
import '../../../core/device/device_student_registration_lock.dart';
import '../check_in_rejection.dart';
import '../check_in_validation.dart'
    show
        isPositionWithinSession,
        isTimestampWithinSessionBounds,
        pendingReplayLocationOk,
        resolveCourseForStudentCheckIn;
import '../../../core/connectivity/app_connectivity.dart';
import '../../../core/firebase/firestore_collections.dart';
import '../../../core/firebase/session_rtd_sync.dart';
import '../../../core/firebase/u_panel_firestore.dart';
import 'package:flutter/services.dart';
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
  static final List<StreamSubscription<void>> _sessionRtdPublishSubs = [];

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

  /// Result of [processOnCreate] — whether to persist locally.
  static Future<({bool discardLocal, PendingSessionCodeEntry? keepLocal})>
      processOnCreate(PendingSessionCodeEntry entry) async {
    final result = await _tryProcess(entry, DateTime.now());
    if (result is int) {
      switch (result) {
        case _removeSubmitted:
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

      if (SessionRtdSync.pluginAvailable) {
        final rtdSub = SessionRtdSync.watchByCode(code).listen(
          (_) {
            unawaited(drainUrgent());
          },
          onError: (Object e) {
            SessionRtdSync.markPluginUnavailable(e);
            if (kDebugMode && e is! MissingPluginException) {
              debugPrint('PendingSessionCodeSync RTD session watch $code: $e');
            }
          },
        );
        _sessionRtdPublishSubs.add(rtdSub);
      }
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
    for (final sub in _sessionRtdPublishSubs) {
      await sub.cancel();
    }
    _sessionRtdPublishSubs.clear();
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

      await AttendanceRepository.instance.prefetchSessionsForPendingCodes();

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
      await AttendanceRepository.instance.prefetchSessionsForPendingCodes();
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

    // Prefer the live open session for this code (ignore stale sessionId hints).
    final byCode = AttendanceRepository.instance.validateSessionCode(
      entry.sessionCodeRaw,
    );
    if (byCode != null) return byCode;

    if (hint != null && hint.isNotEmpty) {
      final byId = AttendanceStore.sessionById(hint);
      if (byId != null &&
          normalizeSessionCodeInput(byId.sessionCode) == normalizedCode &&
          byId.isOpenForCheckIn) {
        return byId;
      }
    }
    return null;
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
        await repo.resolveStudentForRegistration(
          entry.registrationNumber,
          fast: true,
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
        deferHeavyWork: true,
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
      case StudentOfflineCheckInOutcome.queuedOffline:
        return _trustedOfflinePresentEntry(
          entry: withMeta,
          session: session,
          student: student,
          course: course,
        );
      case StudentOfflineCheckInOutcome.deviceBlocked:
        return withMeta.copyWith(
          status: PendingSessionCodeStatus.deviceBlocked,
          note: deviceAlreadyUsedUserMessage,
        );
    }
  }

  static PendingSessionCodeEntry _trustedOfflinePresentEntry({
    required PendingSessionCodeEntry entry,
    required AttendanceSession session,
    required StudentRecord student,
    required String course,
  }) {
    final record = AttendanceRecord(
      id: '${session.id}_${student.id}',
      sessionId: session.id,
      studentId: student.id,
      course: course,
      timestamp: entry.capturedAt,
      latitude: entry.latitude,
      longitude: entry.longitude,
      verified: false,
      present: true,
      deviceId: entry.deviceId,
    );
    final existing = AttendanceStore.attendanceRecordForSessionStudent(
      session.id,
      student.id,
    );
    if (existing == null) {
      AttendanceStore.addAttendanceRecordIfAbsent(record);
    } else if (!existing.verified) {
      AttendanceStore.updateAttendanceRecord(record);
    }
    AttendanceRepository.instance.notifyAttendanceStoreUpdated();
    return entry.copyWith(
      sessionId: session.id,
      listId: session.listId,
      status: PendingSessionCodeStatus.queued,
      note:
          'Check-in saved offline — counted present on this device; will keep syncing.',
      invalidMarkedAt: null,
    );
  }

  /// Claim is on Firestore but check-in is not verified yet — keep local queue
  /// row and retry upload/verification until accepted or rejected.
  static Future<Object> _resolveUploadedClaim({
    required PendingSessionCodeEntry entry,
    required StudentRecord student,
    required DateTime now,
    AttendanceSession? localSessionHint,
  }) async {
    final repo = AttendanceRepository.instance;
    final claimId = PendingSessionCodeClaimUpload.claimDocId(
      normalizedCode: normalizeSessionCodeInput(entry.sessionCodeRaw),
      studentId: student.id,
    );

    final rejection =
        await repo.fetchCheckInAttemptRejectionReason(claimId);
    if (rejection != null) {
      discardLocalAttendanceSideEffects(entry);
      return entry.copyWith(
        status: PendingSessionCodeStatus.invalidOrExpired,
        note: rejection,
        invalidMarkedAt: now,
      );
    }

    if (await PendingSessionCodeClaimUpload.tryRefreshLocalFromServerClaim(
      entry: entry,
      studentId: student.id,
    )) {
      return _removeSubmitted;
    }

    var session = localSessionHint;
    session ??= await repo.resolvePublishedLecturerSessionForPendingClaim(
      sessionCodeRaw: entry.sessionCodeRaw,
      capturedAt: entry.capturedAt,
      sessionIdHint: entry.sessionId,
    );

    if (session != null) {
      await PendingSessionCodeClaimUpload.linkPublishedSessionToClaim(
        entry: entry,
        studentId: student.id,
        session: session,
      );
      return _completeLinkedPendingEntry(
        entry: entry,
        session: session,
        now: now,
        studentForGuard: student,
      );
    }

    return entry.copyWith(
      sessionId: localSessionHint?.id ?? entry.sessionId,
      listId: localSessionHint?.listId ?? entry.listId,
      status: PendingSessionCodeStatus.queued,
      note:
          'Check-in saved on this device — uploaded to server, waiting to verify '
          '(up to ${PendingRetention.unverifiedPending.inDays} days).',
      invalidMarkedAt: null,
    );
  }

  /// Upload student claim metadata if needed; never drops the local row until
  /// check-in is verified or permanently rejected.
  static Future<Object> _ensureClaimUploadedAndResolve({
    required PendingSessionCodeEntry entry,
    required StudentRecord student,
    required DateTime now,
    AttendanceSession? localSessionHint,
  }) async {
    var onServer = await PendingSessionCodeClaimUpload.isClaimOnServer(
      entry: entry,
      studentId: student.id,
    );
    if (!onServer) {
      final uploaded = await PendingSessionCodeClaimUpload.uploadForEntryWithStudent(
        entry: entry,
        studentId: student.id,
      );
      if (!uploaded) {
        return entry.copyWith(
          sessionId: localSessionHint?.id ?? entry.sessionId,
          listId: localSessionHint?.listId ?? entry.listId,
          status: PendingSessionCodeStatus.queued,
          note:
              'Could not upload session metadata yet — saved on this device. '
              'Will retry when the connection is stable.',
          invalidMarkedAt: null,
        );
      }
      onServer = await PendingSessionCodeClaimUpload.isClaimOnServer(
        entry: entry,
        studentId: student.id,
      );
      if (!onServer) {
        return entry.copyWith(
          sessionId: localSessionHint?.id ?? entry.sessionId,
          listId: localSessionHint?.listId ?? entry.listId,
          status: PendingSessionCodeStatus.queued,
          note:
              'Upload did not confirm on server yet — saved on this device. '
              'Will retry shortly.',
          invalidMarkedAt: null,
        );
      }
    }

    return _resolveUploadedClaim(
      entry: entry,
      student: student,
      now: now,
      localSessionHint: localSessionHint,
    );
  }

  static Future<Object> _tryProcess(
    PendingSessionCodeEntry entry,
    DateTime now,
  ) async {
    if (entry.status == PendingSessionCodeStatus.deviceBlocked) {
      return entry;
    }

    final repo = AttendanceRepository.instance;
    final studentForGuard = await repo.resolveStudentForRegistration(
      entry.registrationNumber,
      fast: true,
    );
    if (studentForGuard != null) {
      final block = await PendingSessionCodeClaimUpload.localDeviceBlockReason(
        entry,
        studentId: studentForGuard.id,
      );
      if (block != null) {
        return entry.copyWith(
          status: PendingSessionCodeStatus.deviceBlocked,
          note: block,
        );
      }
      await repo.ensureStudentDocOnServer(studentForGuard.id);
    }

    final linked = _sessionLinkedInStore(entry);
    if (linked != null) {
      if (studentForGuard != null) {
        await PendingSessionCodeClaimUpload.linkPublishedSessionToClaim(
          entry: entry,
          studentId: studentForGuard.id,
          session: linked,
        );
      }
      return _completeLinkedPendingEntry(
        entry: entry,
        session: linked,
        now: now,
        studentForGuard: studentForGuard,
      );
    }

    var session = await repo.resolvePublishedLecturerSessionForPendingClaim(
      sessionCodeRaw: entry.sessionCodeRaw,
      capturedAt: entry.capturedAt,
      sessionIdHint: entry.sessionId,
    );
    if (session != null && studentForGuard != null) {
      await PendingSessionCodeClaimUpload.linkPublishedSessionToClaim(
        entry: entry,
        studentId: studentForGuard.id,
        session: session,
      );
      return _completeLinkedPendingEntry(
        entry: entry,
        session: session,
        now: now,
        studentForGuard: studentForGuard,
      );
    }
    if (session == null) {
      final localOnly = await repo.resolveSessionForPendingCodeEntry(
        sessionCodeRaw: entry.sessionCodeRaw,
        capturedAt: entry.capturedAt,
        sessionIdHint: entry.sessionId,
      );
      if (localOnly != null &&
          !await repo.isLecturerSessionPublishedOnServer(localOnly.id)) {
        final student = studentForGuard ??
            await repo.resolveStudentForRegistration(
              entry.registrationNumber,
              fast: true,
            );
        if (student != null) {
          return _ensureClaimUploadedAndResolve(
            entry: entry,
            student: student,
            now: now,
            localSessionHint: localOnly,
          );
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
          await repo.resolveStudentForRegistration(
          entry.registrationNumber,
          fast: true,
        );
      if (student != null) {
        final resolved = await _ensureClaimUploadedAndResolve(
          entry: entry,
          student: student,
          now: now,
        );
        if (resolved is int) return resolved;
        final updated = resolved as PendingSessionCodeEntry;
        session = await repo.resolvePublishedLecturerSessionForPendingClaim(
          sessionCodeRaw: entry.sessionCodeRaw,
          capturedAt: entry.capturedAt,
          sessionIdHint: updated.sessionId ?? entry.sessionId,
        );
        if (session == null) {
          return updated;
        }
        return _completeLinkedPendingEntry(
          entry: updated,
          session: session,
          now: now,
          studentForGuard: student,
        );
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
    if (!isTimestampWithinSessionBounds(session, boundsTime) && kDebugMode) {
      debugPrint(
        'PendingSessionCodeSync: offline trust for ${entry.sessionCodeRaw} — '
        'capture time outside live session window (session ${session.id}).',
      );
    }
    if (!pendingReplayLocationOk(
      session,
      entry.latitude,
      entry.longitude,
    )) {
      if (kDebugMode) {
        debugPrint(
          'PendingSessionCodeSync: GPS soft-fail for ${entry.sessionCodeRaw} '
          '(session ${session.id}) — submitting for server verification.',
        );
      }
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
      fast: true,
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
        deferHeavyWork: true,
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
      case StudentOfflineCheckInOutcome.queuedOffline:
        return _trustedOfflinePresentEntry(
          entry: withMeta,
          session: session,
          student: student,
          course: course,
        );
      case StudentOfflineCheckInOutcome.deviceBlocked:
        return withMeta.copyWith(
          status: PendingSessionCodeStatus.deviceBlocked,
          note: deviceAlreadyUsedUserMessage,
        );
    }
  }
}
