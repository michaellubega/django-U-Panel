import 'dart:async';

import '../../core/auth/auth_repository.dart';
import '../../core/api/rtd_stubs.dart';
import 'data/attendance_repository.dart';
import 'data/attendance_rtd_record_watch.dart';
import 'models/attendance_models.dart';

/// Same live-update pipeline lecturers use on roll screens — RTD + Firestore
/// record watches, with optional per-list RTD prefetch for students.
abstract final class StudentAttendanceLiveSync {
  StudentAttendanceLiveSync._();

  static Future<void> activate({String? prioritizeListId}) async {
    if (!AuthRepository.instance.isLoggedIn) return;

    await AttendanceRepository.instance.warmFromLocalSnapshot();
    await AuthRepository.instance.ensureStudentRegistrationHydrated();
    if (!AttendanceRepository.isStudentRecordWatchUser()) return;

    await StudentRtdIndex.publishCurrentStudentRegistration();

    await AttendanceRtdRecordWatch.instance.start();

    await AttendanceRepository.instance.refreshStudentProfileFromRtd();

    final prioritized = prioritizeListId?.trim() ?? '';
    if (prioritized.isNotEmpty) {
      AttendanceRepository.instance.touchRecentListDetail(prioritized);
      unawaited(
        AttendanceRepository.instance.refreshStudentListAttendanceFromRtd(
          prioritized,
        ),
      );
    }

    final reg = AuthRepository.instance.currentRegistrationNumber?.trim();
    if (reg == null || reg.isEmpty) return;

    for (final listId
        in AttendanceStore.enrolledListIdsForRegistrationNormalized(reg)) {
      if (listId == prioritized) continue;
      unawaited(
        AttendanceRepository.instance.refreshStudentListAttendanceFromRtd(
          listId,
        ),
      );
    }
  }

  /// Awaited when the profile tab opens — refreshes class list % and records.
  static Future<void> refreshProfileOnVisible() async {
    if (!AuthRepository.instance.isLoggedIn) return;
    await AuthRepository.instance.ensureStudentRegistrationHydrated();
    if (!AttendanceRepository.isStudentRecordWatchUser()) return;

    await StudentRtdIndex.publishCurrentStudentRegistration();
    await AttendanceRtdRecordWatch.instance.start();
    await AttendanceRepository.instance.refreshStudentProfileFromRtd();

    final reg = AuthRepository.instance.currentRegistrationNumber?.trim();
    if (reg != null && reg.isNotEmpty) {
      final listIds =
          AttendanceStore.enrolledListIdsForRegistrationNormalized(reg);
      for (final listId in listIds) {
        await AttendanceRepository.instance.refreshStudentListAttendanceFromRtd(
          listId,
        );
      }
    }

    AttendanceRepository.instance.notifyStoreUpdatedFromRtd();
  }
}
