import 'package:flutter/foundation.dart';

import '../../../core/connectivity/app_connectivity.dart';
import '../../../core/api/api_collections.dart';
import '../../../core/api/api_store.dart';
import '../models/attendance_models.dart';
import 'attendance_repository.dart';
import 'pending_list_create_queue.dart';
import 'pending_retention.dart';

/// Uploads attendance lists created offline ([PendingListCreateQueue]).
class PendingListCreateSync {
  PendingListCreateSync._();

  static bool _running = false;

  static Future<void> drain() async {
    if (_running) return;
    _running = true;
    try {
      final pending = await PendingListCreateQueue.loadAll();
      if (pending.isEmpty) return;
      if (!AppConnectivity.instance.hasNetworkInterface) return;
      if (!await AppConnectivity.instance.ensureReachable()) return;

      final firestore = apiStore();
      final now = DateTime.now();
      final keep = <PendingListCreateEntry>[];

      for (final e in pending) {
        if (PendingRetention.isExpired(e.enqueuedAt, now)) {
          if (kDebugMode) {
            debugPrint(
              'PendingListCreateSync: dropped expired list ${e.list.id}',
            );
          }
          continue;
        }

        try {
          var list = e.list;
          final lecturerUid = list.lecturerUid?.trim();
          if ((lecturerUid == null || lecturerUid.isEmpty) &&
              e.pendingLecturerStaffNumber != null &&
              e.pendingLecturerStaffNumber!.trim().isNotEmpty) {
            final resolvedUid = await AttendanceRepository.instance
                .resolveLecturerUidByStaffNumber(
              e.pendingLecturerStaffNumber!,
            );
            if (resolvedUid == null || resolvedUid.trim().isEmpty) {
              keep.add(e);
              continue;
            }
            list = AttendanceList(
              id: list.id,
              time: list.time,
              room: list.room,
              whoTaught: list.whoTaught,
              date: list.date,
              program: list.program,
              courses: list.courses,
              year: list.year,
              sem: list.sem,
              createdBy: list.createdBy,
              lecturerUid: resolvedUid,
              expectedParticipants: list.expectedParticipants,
              status: list.status,
              lecturerSignCode: list.lecturerSignCode,
              lecturerSignedAt: list.lecturerSignedAt,
              courseUnitName: list.courseUnitName,
            );
            AttendanceStore.updateList(list);
          }

          await firestore
              .collection(ApiCollections.attendanceLists)
              .doc(list.id)
              .set(AttendanceRepository.listToFirestoreMapForSync(list))
              .timeout(AttendanceRepository.listPublishTimeout);
          AttendanceStore.addList(list);
          AttendanceRepository.instance.markListPublishedOnServer(list.id);
          await PendingListCreateQueue.removeByListId(list.id);
          AttendanceRepository.instance.notifyAttendanceStoreUpdated();
        } catch (err) {
          if (kDebugMode) {
            debugPrint(
              'PendingListCreateSync: keep list ${e.list.id} after error: $err',
            );
          }
          AttendanceStore.updateList(e.list);
          keep.add(e);
        }
      }

      await PendingListCreateQueue.saveAll(keep);
    } finally {
      _running = false;
    }
  }
}
