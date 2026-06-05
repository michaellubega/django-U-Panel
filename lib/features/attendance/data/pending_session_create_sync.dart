import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../../../core/connectivity/app_connectivity.dart';
import '../../../core/firebase/firestore_collections.dart';
import '../../../core/firebase/u_panel_firestore.dart';
import '../../notices/data/notices_repository.dart';
import '../models/attendance_models.dart';
import 'attendance_repository.dart';
import 'pending_retention.dart';
import 'pending_session_create_queue.dart';

/// Uploads sessions that were started offline ([PendingSessionCreateQueue]).
class PendingSessionCreateSync {
  PendingSessionCreateSync._();

  static bool _running = false;

  static Future<void> drain() async {
    if (_running) return;
    _running = true;
    try {
      final pending = await PendingSessionCreateQueue.loadAll();
      if (pending.isEmpty) return;
      if (!AppConnectivity.instance.isOnline) return;

      final firestore = uPanelFirestore();
      final now = DateTime.now();
      final keep = <PendingSessionCreateEntry>[];

      for (final e in pending) {
        if (PendingRetention.isExpired(e.enqueuedAt, now)) {
          if (kDebugMode) {
            debugPrint(
              'PendingSessionCreateSync: dropped expired session ${e.sessionId}',
            );
          }
          continue;
        }

        final existing = AttendanceStore.sessionById(e.sessionId);
        if (existing != null && existing.listId == e.listId) {
          // Already in memory from offline start; still try Firestore.
        }

        try {
          final list = AttendanceStore.listById(e.listId);
          if (list != null && list.status != AttendanceListStatus.closed) {
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
            await firestore
                .collection(FirestoreCollections.attendanceLists)
                .doc(e.listId)
                .set(
                  AttendanceRepository.listToFirestoreMapForSync(updated),
                  SetOptions(merge: true),
                );
          }

          await firestore
              .collection(FirestoreCollections.attendanceSessions)
              .doc(e.sessionId)
              .set({
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
          });
          if (AttendanceStore.sessionById(e.sessionId) == null) {
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
          final syncedList = AttendanceStore.listById(e.listId);
          final syncedSession = AttendanceStore.sessionById(e.sessionId);
          if (syncedList != null &&
              syncedSession != null &&
              !e.remoteLearning) {
            await NoticesRepository.instance.publishSessionStartNotice(
              list: syncedList,
              session: syncedSession,
              createdBy: e.createdBy,
            );
          }
          continue;
        } catch (err) {
          if (kDebugMode) {
            debugPrint(
              'PendingSessionCreateSync: keep ${e.sessionId} after error: $err',
            );
          }
          keep.add(e);
        }
      }

      await PendingSessionCreateQueue.saveAll(keep);
    } finally {
      _running = false;
    }
  }
}
