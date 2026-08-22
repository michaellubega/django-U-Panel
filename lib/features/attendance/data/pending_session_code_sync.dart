import 'dart:async';

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
import '../../../core/api/api_collections.dart';
import '../../../core/api/rtd_stubs.dart';
import '../../../core/api/api_store.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import '../models/attendance_models.dart';
import 'attendance_repository.dart';
import 'pending_retention.dart';
import 'pending_session_code_queue.dart';
import 'pending_session_code_claim_upload.dart';
import '../../../core/push/local_push_display.dart';

class PendingSessionCodeSync {
  PendingSessionCodeSync._();

  static const _uploadParallelism = 4;
  static const _approvalParallelism = 3;
  static const _maxUploadsPerDrain = 16;
  static const _maxApprovalChecksPerDrain = 12;

  static int _drainDepth = 0;
  static bool get isDraining => _drainDepth > 0;

  static Future<void>? _drainTail;
  static final Set<String> _watchedPublishCodes = {};
  static final List<StreamSubscription<ApiQuerySnapshot>>
      _sessionPublishSubs = [];
  static final List<StreamSubscription<void>> _sessionRtdPublishSubs = [];

  static Future<void> _withDrainLock(Future<void> Function() body) async {
    final prior = _drainTail;
    final gate = Completer<void>();
    _drainTail = gate.future;
    if (prior != null) {
      await prior;
    }
    _drainDepth++;
    try {
      await body();
    } finally {
      _drainDepth--;
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

  static ({
    List<PendingSessionCodeEntry> keep,
    List<String> droppedIds,
    int invalidRemovedCount,
  }) _partitionQueueForDrain(
    List<PendingSessionCodeEntry> all,
    DateTime now,
  ) {
    final keep = <PendingSessionCodeEntry>[];
    final droppedIds = <String>[];
    var invalidRemovedCount = 0;
    for (final entry in all) {
      if (_shouldDropInvalidMismatchNow(entry, now)) {
        droppedIds.add(entry.id);
        _dropExpiredEntry(entry);
        invalidRemovedCount++;
        continue;
      }
      if (PendingRetention.isExpired(entry.pendingSince, now)) {
        droppedIds.add(entry.id);
        _dropExpiredEntry(entry);
        invalidRemovedCount++;
        continue;
      }
      keep.add(entry);
    }
    return (
      keep: keep,
      droppedIds: droppedIds,
      invalidRemovedCount: invalidRemovedCount,
    );
  }

  /// Merges online drain results without dropping rows enqueued during network I/O.
  static List<PendingSessionCodeEntry> _mergeDrainResults({
    required List<PendingSessionCodeEntry> current,
    required Set<String> drainInputIds,
    required List<PendingSessionCodeEntry> processedRemaining,
  }) {
    final processedById = {
      for (final e in processedRemaining) e.id: e,
    };
    final out = <PendingSessionCodeEntry>[];
    final seen = <String>{};

    for (final row in current) {
      if (processedById.containsKey(row.id)) {
        final proc = processedById[row.id]!;
        out.add(
          proc.uploadedAt == null && row.uploadedAt != null
              ? proc.copyWith(uploadedAt: row.uploadedAt)
              : proc,
        );
        seen.add(row.id);
      } else if (!drainInputIds.contains(row.id)) {
        out.add(row);
        seen.add(row.id);
      }
    }
    for (final e in processedRemaining) {
      if (!seen.contains(e.id)) {
        out.add(e);
      }
    }
    return out;
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
          return (
            discardLocal: false,
            keepLocal: entry.copyWith(
              status: PendingSessionCodeStatus.approved,
              note: 'Check-in approved.',
              invalidMarkedAt: null,
            ),
          );
        case _rejectVerifiedMismatch:
          return (
            discardLocal: false,
            keepLocal: entry.copyWith(
              status: PendingSessionCodeStatus.invalidOrExpired,
              invalidMarkedAt: entry.invalidMarkedAt ?? DateTime.now(),
              note:
                  'Session code matched but check-in time or location was outside class bounds.',
            ),
          );
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
    final db = tryApiStore();
    if (db == null) return;
    for (final raw in rawCodes) {
      final code = normalizeSessionCodeInput(raw);
      if (!isValidJoinCodeFormat(code) || !_watchedPublishCodes.add(code)) {
        continue;
      }
      final sub = db
          .collection(ApiCollections.attendanceSessions)
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
      final entries = await PendingSessionCodeQueue.loadAll();
      final codes = entries
          .map((e) => e.sessionCodeRaw)
          .where((c) => c.trim().isNotEmpty);
      ensureWatchingSessionPublishForCodes(codes);
      final repo = AttendanceRepository.instance;
      for (final entry in entries) {
        final student = await repo.resolveStudentForRegistration(
          entry.registrationNumber,
          fast: true,
        );
        if (student == null) continue;
        repo.watchPendingSessionCodeClaim(
          entry: entry,
          studentId: student.id,
        );
      }
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
      final initial = await PendingSessionCodeQueue.loadAll();
      if (initial.isEmpty) {
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
      var invalidRemovedCount = 0;

      if (!AppConnectivity.instance.hasNetworkInterface ||
          !await AppConnectivity.instance.ensureReachable()) {
        var offlineInvalidRemoved = 0;
        final remaining = await PendingSessionCodeQueue.mutate((all) async {
          final partition = _partitionQueueForDrain(all, now);
          offlineInvalidRemoved = partition.invalidRemovedCount;
          return partition.keep;
        });
        await PendingSessionCodeQueue.saveLastSyncResult(
          PendingSessionSyncResult(
            ranAt: now,
            startedCount: initial.length,
            remainingCount: remaining.length,
            autoSubmittedCount: 0,
            needsRegistrationCount: 0,
            invalidMarkedCount: 0,
            invalidRemovedCount: offlineInvalidRemoved,
            deviceBlockedCount: 0,
          ),
        );
        return;
      }

      var processedResult = (
        remaining: <PendingSessionCodeEntry>[],
        autoSubmittedCount: 0,
        needsRegistrationCount: 0,
        invalidMarkedCount: 0,
        invalidRemovedCount: 0,
        deviceBlockedCount: 0,
        hadDeferredUploads: false,
      );

      var partition = (
        keep: <PendingSessionCodeEntry>[],
        droppedIds: <String>[],
        invalidRemovedCount: 0,
      );
      final keep = await PendingSessionCodeQueue.mutate((all) async {
        partition = _partitionQueueForDrain(all, now);
        invalidRemovedCount = partition.invalidRemovedCount;
        return partition.keep;
      });
      if (keep.isEmpty) {
        await PendingSessionCodeQueue.saveLastSyncResult(
          PendingSessionSyncResult(
            ranAt: now,
            startedCount: initial.length,
            remainingCount: 0,
            autoSubmittedCount: 0,
            needsRegistrationCount: 0,
            invalidMarkedCount: 0,
            invalidRemovedCount: invalidRemovedCount,
            deviceBlockedCount: 0,
          ),
        );
        return;
      }

      final drainInputIds = keep.map((e) => e.id).toSet();
      final anyNeedsLinking = keep.any((e) => e.hasLocalUploadEvidence);
      if (anyNeedsLinking) {
        await AttendanceRepository.instance.prefetchSessionsForPendingCodes();
      }
      processedResult = await _processEntriesOnline(keep, now);

      final remaining = await PendingSessionCodeQueue.mutate((current) async {
        return _mergeDrainResults(
          current: current,
          drainInputIds: drainInputIds,
          processedRemaining: processedResult.remaining,
        );
      });
      refreshSessionPublishWatchesFromQueue();
      if (processedResult.hadDeferredUploads) {
        unawaited(Future.microtask(drainUrgent));
      }
      await PendingSessionCodeQueue.saveLastSyncResult(
        PendingSessionSyncResult(
          ranAt: now,
          startedCount: initial.length,
          remainingCount: remaining.length,
          autoSubmittedCount: processedResult.autoSubmittedCount,
          needsRegistrationCount: processedResult.needsRegistrationCount,
          invalidMarkedCount: processedResult.invalidMarkedCount,
          invalidRemovedCount:
              invalidRemovedCount + processedResult.invalidRemovedCount,
          deviceBlockedCount: processedResult.deviceBlockedCount,
        ),
      );
  }

  /// Session-code queue only (no [loadAll]). Use [AttendanceOfflineSync.drainAllInOrder].
  static Future<void> drainWithoutReload() async {
    await _withDrainLock(() => _drainBodyWithoutReload(urgent: false));
  }

  static Future<void> _drainBodyWithoutReload({required bool urgent}) async {
      if (!AppConnectivity.instance.hasNetworkInterface) return;
      if (!urgent &&
          !await AppConnectivity.instance.ensureReachable(
            timeout: const Duration(seconds: 3),
          )) {
        return;
      }

      final now = DateTime.now();
      final startedCount = (await PendingSessionCodeQueue.loadAll()).length;
      if (startedCount == 0) return;

      var partition = (
        keep: <PendingSessionCodeEntry>[],
        droppedIds: <String>[],
        invalidRemovedCount: 0,
      );
      final keep = await PendingSessionCodeQueue.mutate((all) async {
        partition = _partitionQueueForDrain(all, now);
        return partition.keep;
      });
      if (keep.isEmpty) return;

      final drainInputIds = keep.map((e) => e.id).toSet();
      final anyNeedsLinking = keep.any((e) => e.hasLocalUploadEvidence);
      if (anyNeedsLinking) {
        await AttendanceRepository.instance.prefetchSessionsForPendingCodes();
      }
      final processed = await _processEntriesOnline(keep, now);

      await PendingSessionCodeQueue.mutate((current) async {
        return _mergeDrainResults(
          current: current,
          drainInputIds: drainInputIds,
          processedRemaining: processed.remaining,
        );
      });
      refreshSessionPublishWatchesFromQueue();
      if (processed.hadDeferredUploads) {
        unawaited(Future.microtask(drainUrgent));
      }
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

  static bool _shouldDropInvalidMismatchNow(
    PendingSessionCodeEntry entry,
    DateTime now,
  ) {
    if (!_dropVerifiedMismatchInvalid(entry)) return false;
    final marked = entry.invalidMarkedAt ?? entry.pendingSince;
    return PendingRetention.isExpired(marked, now);
  }

  static Future<
      ({
        List<PendingSessionCodeEntry> remaining,
        int autoSubmittedCount,
        int needsRegistrationCount,
        int invalidMarkedCount,
        int invalidRemovedCount,
        int deviceBlockedCount,
        bool hadDeferredUploads,
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

    final needsUpload = <PendingSessionCodeEntry>[];
    final alreadyUploaded = <PendingSessionCodeEntry>[];
    for (final entry in keep) {
      if (entry.hasLocalUploadEvidence) {
        alreadyUploaded.add(entry);
      } else {
        needsUpload.add(entry);
      }
    }

    final uploadBatch = needsUpload.length > _maxUploadsPerDrain
        ? needsUpload.sublist(0, _maxUploadsPerDrain)
        : needsUpload;
    final deferredUpload = needsUpload.length > _maxUploadsPerDrain
        ? needsUpload.sublist(_maxUploadsPerDrain)
        : const <PendingSessionCodeEntry>[];

    Future<void> applyResult(Object result, PendingSessionCodeEntry entry) async {
      if (result is int) {
        if (result == _removeSubmitted) {
          autoSubmittedCount++;
          onlineKeep.add(
            entry.copyWith(
              status: PendingSessionCodeStatus.approved,
              note: 'Check-in approved.',
              invalidMarkedAt: null,
            ),
          );
          AttendanceRepository.instance.notifyAttendanceStoreUpdated();
        } else if (result == _rejectVerifiedMismatch) {
          invalidMarkedCount++;
          onlineKeep.add(
            entry.copyWith(
              status: PendingSessionCodeStatus.invalidOrExpired,
              invalidMarkedAt: entry.invalidMarkedAt ?? now,
              note:
                  'Session code matched but check-in time or location was outside class bounds.',
            ),
          );
        }
        return;
      }
      var updated = result as PendingSessionCodeEntry;
      if (updated.status == PendingSessionCodeStatus.invalidOrExpired) {
        final marked = updated.invalidMarkedAt ?? updated.pendingSince;
        if (PendingRetention.isExpired(marked, now)) {
          invalidRemovedCount++;
          return;
        }
        invalidMarkedCount++;
      } else if (updated.status == PendingSessionCodeStatus.needsRegistration) {
        needsRegistrationCount++;
        // After the 2nd consecutive retry, surface a local notification so the
        // student sees "check your profile" even with the app in the background.
        if (updated.retryCount >= 2) {
          unawaited(_notifyNeedsRegistration(updated));
        }
      } else if (updated.status == PendingSessionCodeStatus.deviceBlocked) {
        deviceBlockedCount++;
      } else if (updated.status == PendingSessionCodeStatus.approved) {
        autoSubmittedCount++;
      } else if (updated.status == PendingSessionCodeStatus.queued &&
          !updated.hasLocalUploadEvidence) {
        // Transient failure (network, server error): bump retry counter.
        // After 5 consecutive failures surface uploadFailed so the user knows.
        final newRetry = updated.retryCount + 1;
        const maxRetries = 5;
        updated = updated.copyWith(
          retryCount: newRetry,
          status: newRetry >= maxRetries
              ? PendingSessionCodeStatus.uploadFailed
              : PendingSessionCodeStatus.queued,
          note: newRetry >= maxRetries
              ? 'Upload failed after several attempts. Will retry automatically '
                'when the connection is stable. Tap Pending Sessions to retry now.'
              : updated.note,
        );
      }
      onlineKeep.add(updated);
    }

    final pendingApproval = <PendingSessionCodeEntry>[...alreadyUploaded];
    final uploadOnlyKeep = <PendingSessionCodeEntry>[];

    for (var i = 0; i < uploadBatch.length; i += _uploadParallelism) {
      final end = i + _uploadParallelism > uploadBatch.length
          ? uploadBatch.length
          : i + _uploadParallelism;
      final chunk = uploadBatch.sublist(i, end);
      final chunkResults = await Future.wait(
        chunk.map((entry) async {
          final result = await _tryUploadOnly(entry, now);
          return (entry: entry, result: result);
        }),
      );
      for (final row in chunkResults) {
        final result = row.result;
        if (result is PendingSessionCodeEntry && result.hasLocalUploadEvidence) {
          pendingApproval.add(result);
          continue;
        }
        if (result is PendingSessionCodeEntry) {
          uploadOnlyKeep.add(result);
          continue;
        }
        await applyResult(result, row.entry);
      }
    }
    onlineKeep.addAll(uploadOnlyKeep);
    onlineKeep.addAll(deferredUpload);

    var approvalChecks = 0;
    for (var i = 0; i < pendingApproval.length; i += _approvalParallelism) {
      if (approvalChecks >= _maxApprovalChecksPerDrain) {
        onlineKeep.addAll(pendingApproval.skip(i));
        break;
      }
      final remainingBudget = _maxApprovalChecksPerDrain - approvalChecks;
      final chunkSize = remainingBudget < _approvalParallelism
          ? remainingBudget
          : _approvalParallelism;
      final end = i + chunkSize > pendingApproval.length
          ? pendingApproval.length
          : i + chunkSize;
      final chunk = pendingApproval.sublist(i, end);
      approvalChecks += chunk.length;
      final results = await Future.wait(
        chunk.map((entry) => _fastPathUploadedEntry(entry, now)),
      );
      for (var j = 0; j < chunk.length; j++) {
        await applyResult(results[j], chunk[j]);
      }
    }

    return (
      remaining: onlineKeep,
      autoSubmittedCount: autoSubmittedCount,
      needsRegistrationCount: needsRegistrationCount,
      invalidMarkedCount: invalidMarkedCount,
      invalidRemovedCount: invalidRemovedCount,
      deviceBlockedCount: deviceBlockedCount,
      hadDeferredUploads: deferredUpload.isNotEmpty,
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
    if (await repo.pendingSessionCodeResolvedOnServer(
      entry: withMeta,
      studentId: student.id,
      session: session,
    )) {
      return _removeSubmitted;
    }

    if (withMeta.hasLocalUploadEvidence) {
      await PendingSessionCodeClaimUpload.linkPublishedSessionToClaim(
        entry: withMeta,
        studentId: student.id,
        session: session,
      );
      if (await repo.pendingSessionCodeResolvedOnServer(
        entry: withMeta,
        studentId: student.id,
        session: session,
      )) {
        return _removeSubmitted;
      }
      if (await PendingSessionCodeClaimUpload.tryRefreshLocalFromServerClaim(
        entry: withMeta,
        studentId: student.id,
      )) {
        return _removeSubmitted;
      }
      unawaited(
        repo.awaitOfficialRecordFromApi(
          sessionId: session.id,
          studentId: student.id,
          timeout: const Duration(seconds: 12),
        ),
      );
      return withMeta.copyWith(
        status: PendingSessionCodeStatus.queued,
        note:
            withMeta.note?.trim().isNotEmpty == true
                ? withMeta.note
                : 'Uploaded to server — waiting for verification '
                    '(up to ${PendingRetention.unverifiedPending.inDays} days).',
        invalidMarkedAt: null,
      );
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
      verified: false,
      present: true,
      deviceId: entry.deviceId,
    );
    final outcome = await repo.submitStudentCheckInWithOfflineSupport(
      record,
      listIdOverride: list.id,
      sessionCodeRaw: entry.sessionCodeRaw,
    );
    return _afterCheckInSubmitOutcome(
      withMeta: withMeta,
      session: session,
      list: list,
      student: student,
      course: course,
      outcome: outcome,
      awaitVerification: true,
    );
  }

  static Future<Object> _afterCheckInSubmitOutcome({
    required PendingSessionCodeEntry withMeta,
    required AttendanceSession session,
    required AttendanceList list,
    required StudentRecord student,
    required String course,
    required StudentOfflineCheckInOutcome outcome,
    bool awaitVerification = false,
  }) async {
    final repo = AttendanceRepository.instance;

    Future<void> ensureSignIn() async {
      if (!AttendanceStore.hasSignedIn(list.id, student.id, course)) {
        unawaited(
          repo.ensureSignInAndBackfillPastAbsents(
            listId: list.id,
            studentId: student.id,
            course: course,
          ),
        );
      }
    }

    switch (outcome) {
      case StudentOfflineCheckInOutcome.success:
      case StudentOfflineCheckInOutcome.duplicate:
        if (await repo.pendingSessionCodeResolvedOnServer(
          entry: withMeta,
          studentId: student.id,
          session: session,
        )) {
          await ensureSignIn();
          return _removeSubmitted;
        }
        return _trustedOfflinePresentEntry(
          entry: withMeta,
          session: session,
          student: student,
          course: course,
        );
      case StudentOfflineCheckInOutcome.submittedPendingVerification:
        final hasEvidence = withMeta.hasLocalUploadEvidence ||
            await repo.pendingSessionCodeHasServerEvidence(
              entry: withMeta,
              studentId: student.id,
              session: session,
            );
        if (hasEvidence) {
          await ensureSignIn();
          if (!withMeta.hasLocalUploadEvidence) {
            await PendingSessionCodeQueue.markUploaded(withMeta.id);
          }
          if (awaitVerification) {
            unawaited(
              repo.awaitOfficialRecordFromApi(
                sessionId: session.id,
                studentId: student.id,
                timeout: const Duration(seconds: 12),
              ),
            );
          } else {
            await repo.awaitOfficialRecordFromApi(
              sessionId: session.id,
              studentId: student.id,
              timeout: const Duration(seconds: 12),
            );
          }
          return withMeta.copyWith(
            status: PendingSessionCodeStatus.queued,
            note:
                'Uploaded to server — waiting for verification '
                '(up to ${PendingRetention.unverifiedPending.inDays} days).',
            invalidMarkedAt: null,
          );
        }
        return _trustedOfflinePresentEntry(
          entry: withMeta,
          session: session,
          student: student,
          course: course,
        );
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
    if (session != null &&
        !await repo.isLecturerSessionPublishedOnServer(session.id)) {
      session = null;
    }
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
    if (entry.hasLocalUploadEvidence) {
      return _resolveUploadedClaim(
        entry: entry,
        student: student,
        now: now,
        localSessionHint: localSessionHint,
      );
    }
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
      return _resolveUploadedClaim(
        entry: entry.copyWith(uploadedAt: DateTime.now()),
        student: student,
        now: now,
        localSessionHint: localSessionHint,
      );
    }

    return _resolveUploadedClaim(
      entry: entry,
      student: student,
      now: now,
      localSessionHint: localSessionHint,
    );
  }

  static Future<Object> _fastPathUploadedEntry(
    PendingSessionCodeEntry entry,
    DateTime now,
  ) async {
    final repo = AttendanceRepository.instance;
    final student = await repo.resolveStudentForRegistration(
      entry.registrationNumber,
      fast: true,
    );
    if (student == null) return entry;

    AttendanceSession? localHint = _sessionLinkedInStore(entry) ??
        (entry.sessionId?.trim().isNotEmpty == true
            ? AttendanceStore.sessionById(entry.sessionId!.trim())
            : null);
    if (localHint != null &&
        !await repo.isLecturerSessionPublishedOnServer(localHint.id)) {
      localHint = null;
    }

    return _resolveUploadedClaim(
      entry: entry,
      student: student,
      now: now,
      localSessionHint: localHint,
    );
  }

  /// Fast RTD upload during bulk drain — linking/verification runs in approval pass.
  static Future<Object> _tryUploadOnly(
    PendingSessionCodeEntry entry,
    DateTime now,
  ) async {
    if (entry.hasLocalUploadEvidence) return entry;
    if (entry.status == PendingSessionCodeStatus.deviceBlocked) return entry;

    final repo = AttendanceRepository.instance;
    final student = await repo.resolveStudentForRegistration(
      entry.registrationNumber,
      fast: true,
    );
    if (student == null) {
      return entry.copyWith(
        status: PendingSessionCodeStatus.needsRegistration,
        note: 'Student not on roster yet.',
      );
    }

    final block = await PendingSessionCodeClaimUpload.localDeviceBlockReason(
      entry,
      studentId: student.id,
    );
    if (block != null) {
      return entry.copyWith(
        status: PendingSessionCodeStatus.deviceBlocked,
        note: block,
      );
    }

    final uploaded = await PendingSessionCodeClaimUpload.uploadClaimMetadataOnly(
      entry: entry,
      studentId: student.id,
    );
    if (!uploaded) return entry;

    return entry.copyWith(
      uploadedAt: DateTime.now(),
      status: PendingSessionCodeStatus.queued,
      note: 'Uploaded to server — waiting for verification.',
      invalidMarkedAt: null,
    );
  }

  static Future<Object> _tryProcess(
    PendingSessionCodeEntry entry,
    DateTime now,
  ) async {
    if (entry.status == PendingSessionCodeStatus.deviceBlocked) {
      return entry;
    }
    if (entry.hasLocalUploadEvidence) {
      return _fastPathUploadedEntry(entry, now);
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
      unawaited(repo.ensureStudentDocOnServer(studentForGuard.id));
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
      // Always log in all builds so ops/support can diagnose false-absent issues.
      debugPrint(
        'PendingSessionCodeSync: GPS mismatch for ${entry.sessionCodeRaw} '
        '(session ${session.id}) — captured coords (${entry.latitude}, ${entry.longitude}) '
        'are outside the session geofence. Submitting for server-side decision.',
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
    if (await repo.pendingSessionCodeResolvedOnServer(
      entry: withMeta,
      studentId: student.id,
      session: session,
    )) {
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
      verified: false,
      present: true,
      deviceId: entry.deviceId,
    );
    final outcome = await repo.submitStudentCheckInWithOfflineSupport(
      record,
      listIdOverride: list.id,
      sessionCodeRaw: entry.sessionCodeRaw,
    );
    return _afterCheckInSubmitOutcome(
      withMeta: withMeta,
      session: session,
      list: list,
      student: student,
      course: course,
      outcome: outcome,
    );
  }

  static Future<void> _notifyNeedsRegistration(
    PendingSessionCodeEntry entry,
  ) async {
    try {
      await localPushShow(
        id: entry.id.hashCode.abs() & 0x7FFFFFFF,
        title: 'Check-in pending',
        body: 'Your registration number (${entry.registrationNumber}) '
            'was not found on the class roster for session code '
            '${entry.sessionCodeRaw.toUpperCase()}. '
            'Open the app → Profile and verify your registration number.',
      );
    } catch (_) {}
  }
}
