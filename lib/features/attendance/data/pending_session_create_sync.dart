import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../core/auth/auth_repository.dart';
import '../../../core/connectivity/app_connectivity.dart';
import '../../../core/api/api_collections.dart';
import '../../../core/api/rtd_stubs.dart';
import '../../../core/api/api_store.dart';
import '../../notices/data/notices_repository.dart';
import '../check_in_validation.dart';
import '../models/attendance_models.dart';
import 'attendance_repository.dart';
import 'pending_list_create_sync.dart';
import 'pending_retention.dart';
import 'pending_session_code_sync.dart';
import 'pending_session_create_queue.dart';

/// Uploads sessions that were started offline ([PendingSessionCreateQueue]).
class PendingSessionCreateSync {
  PendingSessionCreateSync._();

  static Future<void>? _drainTail;
  static bool _drainAgain = false;
  static final Map<String, DateTime> _retryAfterBySession = {};
  static final Map<String, int> _failureCountBySession = {};

  static Duration get _uploadTimeout =>
      kIsWeb ? const Duration(seconds: 18) : const Duration(seconds: 10);

  static Duration get _probeTimeout =>
      kIsWeb ? const Duration(seconds: 10) : const Duration(seconds: 6);

  static int get _maxParallel => kIsWeb ? 2 : 4;

  static Duration _scheduleRetryAfterFailure(String sessionId) {
    final failures = (_failureCountBySession[sessionId] ?? 0) + 1;
    _failureCountBySession[sessionId] = failures;
    final seconds = (15 * failures).clamp(15, 120);
    return Duration(seconds: seconds);
  }

  static void _clearRetryState(String sessionId) {
    _retryAfterBySession.remove(sessionId);
    _failureCountBySession.remove(sessionId);
  }

  /// Fast path on reconnect: skip reachability probe, upload session docs first.
  static Future<void> drainUrgent() => drain(urgent: true);

  static Future<void> _withDrainLock(Future<void> Function() body) async {
    final prior = _drainTail;
    final gate = Completer<void>();
    _drainTail = gate.future;
    if (prior != null) await prior;
    try {
      do {
        _drainAgain = false;
        await body();
      } while (_drainAgain);
    } finally {
      gate.complete();
    }
  }

  static Future<void> drain({bool urgent = false}) async {
    await _withDrainLock(() => _drainBody(urgent: urgent));
  }

  static Future<void> _drainBody({required bool urgent}) async {
    var pending = await PendingSessionCreateQueue.loadAll();
    if (pending.isEmpty) return;
    if (!AppConnectivity.instance.hasNetworkInterface) return;

    if (!urgent &&
        !await AppConnectivity.instance.ensureReachable(
          timeout: const Duration(seconds: 3),
        )) {
      return;
    }

    final now = DateTime.now();
    final expired = pending
        .where((e) => PendingRetention.isExpired(e.enqueuedAt, now))
        .map((e) => e.sessionId)
        .toSet();
    if (expired.isNotEmpty) {
      pending = pending.where((e) => !expired.contains(e.sessionId)).toList();
      await PendingSessionCreateQueue.saveAll(pending);
      if (kDebugMode) {
        debugPrint(
          'PendingSessionCreateSync: dropped ${expired.length} expired session(s)',
        );
      }
    }
    if (pending.isEmpty) return;

    final firestore = apiStore();
    var uploadedAny = false;
    var skippedBackoff = 0;
    var keptAfterError = 0;

    Future<void> uploadOne(PendingSessionCreateEntry e) async {
      final now = DateTime.now();
      final retryAfter = _retryAfterBySession[e.sessionId];
      if (retryAfter != null && now.isBefore(retryAfter)) {
        skippedBackoff++;
        return;
      }

      try {
        if (!await _ensureListPublished(firestore, e.listId)) {
          _retryAfterBySession[e.sessionId] = now.add(
            urgent ? const Duration(seconds: 8) : const Duration(seconds: 30),
          );
          keptAfterError++;
          return;
        }

        if (await AttendanceRepository.instance
            .firestoreActiveSessionDocExists(e.sessionId)) {
          _ensureSessionInStore(e);
          await _publishSessionToRtdAfterUpload(
            entry: e,
            creatorUid: AuthRepository.instance.currentUserId?.trim(),
          );
          await PendingSessionCreateQueue.removeBySessionId(e.sessionId);
          _clearRetryState(e.sessionId);
          uploadedAny = true;
          return;
        }

        final uploadCode = normalizeSessionCodeInput(e.sessionCode);
        final entry = uploadCode == e.sessionCode
            ? e
            : PendingSessionCreateEntry(
                sessionId: e.sessionId,
                listId: e.listId,
                sessionCode: uploadCode,
                latitude: e.latitude,
                longitude: e.longitude,
                radiusMeters: e.radiusMeters,
                startTime: e.startTime,
                endTime: e.endTime,
                createdBy: e.createdBy,
                enqueuedAt: e.enqueuedAt,
                remoteLearning: e.remoteLearning,
              );
        if (entry.sessionCode != e.sessionCode) {
          final all = await PendingSessionCreateQueue.loadAll();
          final idx = all.indexWhere((x) => x.sessionId == e.sessionId);
          if (idx >= 0) {
            all[idx] = entry;
            await PendingSessionCreateQueue.saveAll(all);
          }
        }

        final session = AttendanceSession(
          id: entry.sessionId,
          listId: entry.listId,
          sessionCode: entry.sessionCode,
          latitude: entry.latitude,
          longitude: entry.longitude,
          radiusMeters: entry.radiusMeters,
          startTime: entry.startTime,
          endTime: entry.endTime,
          status: SessionStatus.active,
          createdBy: entry.createdBy,
          remoteLearning: entry.remoteLearning,
        );
        final metadataReady =
            entry.remoteLearning || isSessionGeofenceConfigured(session);
        final creatorUid = AuthRepository.instance.currentUserId?.trim();
        await firestore
            .collection(ApiCollections.attendanceSessions)
            .doc(entry.sessionId)
            .set(
              AttendanceRepository.activeSessionToFirestoreMapForSync(
                session: session,
                createdByUid: creatorUid,
                locationMetadataPending: !metadataReady && !entry.remoteLearning,
              ),
              ApiSetOptions(merge: true),
            )
            .timeout(_uploadTimeout);

        final confirmedOnServer =
            await AttendanceRepository.instance.firestoreActiveSessionDocExists(
          entry.sessionId,
        );
        if (!confirmedOnServer) {
          keptAfterError++;
          final wait = _scheduleRetryAfterFailure(e.sessionId);
          _retryAfterBySession[e.sessionId] = DateTime.now().add(wait);
          if (kDebugMode) {
            debugPrint(
              'PendingSessionCreateSync: keep ${e.sessionId} '
              '(upload not confirmed on server, retry after ${wait.inSeconds}s)',
            );
          }
          return;
        }

        _ensureSessionInStore(entry);
        await _publishSessionToRtdAfterUpload(
          entry: entry,
          creatorUid: creatorUid,
          locationMetadataPending: !metadataReady && !entry.remoteLearning,
        );
        await PendingSessionCreateQueue.removeBySessionId(e.sessionId);
        _clearRetryState(e.sessionId);
        uploadedAny = true;

        unawaited(_markListActive(firestore, e.listId));
        unawaited(_publishNoticeIfNeeded(e));
      } catch (err) {
        keptAfterError++;
        final wait = _scheduleRetryAfterFailure(e.sessionId);
        _retryAfterBySession[e.sessionId] = DateTime.now().add(wait);
        if (kDebugMode) {
          debugPrint(
            'PendingSessionCreateSync: keep ${e.sessionId} '
            '(retry after ${wait.inSeconds}s): $err',
          );
        }
      }
    }

    for (var i = 0; i < pending.length; i += _maxParallel) {
      final batch = pending.skip(i).take(_maxParallel);
      await Future.wait(batch.map(uploadOne));
    }

    if (kDebugMode && (skippedBackoff > 0 || keptAfterError > 0) && !uploadedAny) {
      debugPrint(
        'PendingSessionCreateSync: ${pending.length} queued, '
        '$skippedBackoff waiting backoff, $keptAfterError deferred',
      );
    }

    if (uploadedAny) {
      AttendanceRepository.instance.notifyAttendanceStoreUpdated();
      unawaited(
        AttendanceRepository.instance.prefetchSessionsForPendingCodes(),
      );
      unawaited(PendingSessionCodeSync.drainUrgent());
    }
  }

  static Future<bool> _ensureListPublished(
    ApiStore firestore,
    String listId,
  ) async {
    final id = listId.trim();
    if (id.isEmpty) return false;
    try {
      final snap = await firestore
          .collection(ApiCollections.attendanceLists)
          .doc(id)
          .get()
          .timeout(_probeTimeout);
      if (snap.exists) return true;
    } catch (_) {}

    await PendingListCreateSync.drain();
    try {
      final snap = await firestore
          .collection(ApiCollections.attendanceLists)
          .doc(id)
          .get()
          .timeout(_probeTimeout);
      return snap.exists;
    } catch (_) {
      return false;
    }
  }

  static void _ensureSessionInStore(PendingSessionCreateEntry e) {
    if (AttendanceStore.sessionById(e.sessionId) != null) return;
    AttendanceStore.addSession(
      AttendanceSession(
        id: e.sessionId,
        listId: e.listId,
        sessionCode: e.sessionCode,
        latitude: e.latitude,
        longitude: e.longitude,
        radiusMeters: e.radiusMeters,
        startTime: e.startTime,
        endTime: e.endTime,
        status: SessionStatus.active,
        createdBy: e.createdBy,
        remoteLearning: e.remoteLearning,
      ),
    );
  }

  static Future<void> _markListActive(
    ApiStore firestore,
    String listId,
  ) async {
    final list = AttendanceStore.listById(listId);
    if (list == null || list.status == AttendanceListStatus.closed) return;

    final updated = AttendanceList(
      id: list.id,
      time: list.time,
      room: list.room,
      whoTaught: list.whoTaught,
      date: list.date,
      program: list.program,
      courses: list.courses ?? list.coursesSafe.toList(),
      year: list.year,
      sem: list.sem,
      createdBy: list.createdBy,
      lecturerUid: list.lecturerUid,
      expectedParticipants: list.expectedParticipants,
      status: AttendanceListStatus.active,
      lecturerSignCode: list.lecturerSignCode,
      lecturerSignedAt: list.lecturerSignedAt,
      courseUnitName: list.courseUnitName,
    );
    AttendanceStore.updateList(updated);
    try {
      await firestore
          .collection(ApiCollections.attendanceLists)
          .doc(listId)
          .set(
            AttendanceRepository.listToFirestoreMapForSync(updated),
            ApiSetOptions(merge: true),
          )
          .timeout(_uploadTimeout);
    } catch (_) {}
  }

  /// RTD publish lets [onRunningSessionRtdWritten] reconcile pending claims
  /// immediately instead of waiting on the Firestore trigger chain alone.
  static Future<void> _publishSessionToRtdAfterUpload({
    required PendingSessionCreateEntry entry,
    required String? creatorUid,
    bool locationMetadataPending = false,
  }) async {
    final session = AttendanceStore.sessionById(entry.sessionId) ??
        AttendanceSession(
          id: entry.sessionId,
          listId: entry.listId,
          sessionCode: entry.sessionCode,
          latitude: entry.latitude,
          longitude: entry.longitude,
          radiusMeters: entry.radiusMeters,
          startTime: entry.startTime,
          endTime: entry.endTime,
          status: SessionStatus.active,
          createdBy: entry.createdBy,
          remoteLearning: entry.remoteLearning,
          locationMetadataPending: locationMetadataPending,
        );
    final published = await SessionRtdSync.publishRunningSession(
      session,
      createdByUid: creatorUid,
      locationMetadataPending: locationMetadataPending,
    );
    if (published) {
      AttendanceRepository.instance.markSessionPublishedOnServer(entry.sessionId);
    }
  }

  static Future<void> _publishNoticeIfNeeded(
    PendingSessionCreateEntry e,
  ) async {
    if (e.remoteLearning) return;
    final list = AttendanceStore.listById(e.listId);
    final session = AttendanceStore.sessionById(e.sessionId);
    if (list == null || session == null) return;
    try {
      await NoticesRepository.instance.publishSessionStartNotice(
        list: list,
        session: session,
        createdBy: e.createdBy,
      );
    } catch (_) {}
  }
}
