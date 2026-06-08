import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../../../core/connectivity/app_connectivity.dart';
import '../../../core/firebase/firestore_collections.dart';
import '../../../core/firebase/u_panel_firestore.dart';
import '../../notices/data/notices_repository.dart';
import '../check_in_validation.dart';
import '../models/attendance_models.dart';
import 'attendance_repository.dart';
import 'pending_retention.dart';
import 'pending_session_code_sync.dart';
import 'pending_session_create_queue.dart';

/// Uploads sessions that were started offline ([PendingSessionCreateQueue]).
class PendingSessionCreateSync {
  PendingSessionCreateSync._();

  static Future<void>? _drainTail;
  static bool _drainAgain = false;

  static const Duration _uploadTimeout = Duration(seconds: 8);
  static const int _maxParallel = 4;

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

    final firestore = uPanelFirestore();
    var uploadedAny = false;

    Future<void> uploadOne(PendingSessionCreateEntry e) async {
      try {
        final uploadCode =
            await AttendanceRepository.instance.ensureJoinCodeForSessionUpload(
          sessionId: e.sessionId,
          sessionCode: e.sessionCode,
        );
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

        await firestore
            .collection(FirestoreCollections.attendanceSessions)
            .doc(entry.sessionId)
            .set(
              _sessionMap(entry),
            )
            .timeout(_uploadTimeout);

        _ensureSessionInStore(entry);
        await PendingSessionCreateQueue.removeBySessionId(e.sessionId);
        uploadedAny = true;

        unawaited(_markListActive(firestore, e.listId));
        unawaited(_publishNoticeIfNeeded(e));
      } catch (err) {
        if (kDebugMode) {
          debugPrint(
            'PendingSessionCreateSync: keep ${e.sessionId} after error: $err',
          );
        }
      }
    }

    for (var i = 0; i < pending.length; i += _maxParallel) {
      final batch = pending.skip(i).take(_maxParallel);
      await Future.wait(batch.map(uploadOne));
    }

    if (uploadedAny) {
      AttendanceRepository.instance.notifyAttendanceStoreUpdated();
      unawaited(
        AttendanceRepository.instance.prefetchSessionsForPendingCodes(),
      );
      unawaited(PendingSessionCodeSync.drainUrgent());
    }
  }

  static Map<String, dynamic> _sessionMap(PendingSessionCreateEntry e) {
    final session = AttendanceSession(
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
    );
    final metadataReady =
        e.remoteLearning || isSessionGeofenceConfigured(session);
    return {
      'listId': e.listId,
      'sessionCode': e.sessionCode,
      'latitude': e.latitude,
      'longitude': e.longitude,
      'radiusMeters': e.radiusMeters,
      'startTime': Timestamp.fromDate(e.startTime),
      'endTime': Timestamp.fromDate(e.endTime),
      'status': SessionStatus.active.name,
      'createdBy': e.createdBy,
      if (e.remoteLearning) 'remoteLearning': true,
      'awaitingStudentMetadata': !metadataReady,
      if (!metadataReady)
        'metadataPendingUntil': Timestamp.fromDate(
          e.startTime.add(PendingRetention.unverifiedPending),
        ),
    };
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
    FirebaseFirestore firestore,
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
          .collection(FirestoreCollections.attendanceLists)
          .doc(listId)
          .set(
            AttendanceRepository.listToFirestoreMapForSync(updated),
            SetOptions(merge: true),
          )
          .timeout(_uploadTimeout);
    } catch (_) {}
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
