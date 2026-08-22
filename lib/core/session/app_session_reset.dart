import '../device/device_student_registration_lock.dart';
import '../notifications/notification_maintenance_coordinator.dart';
import '../push/push_controller.dart';
import '../storage/attendance_local_queues.dart';
import '../../features/attendance/data/attendance_repository.dart';
import '../../features/notices/data/notices_repository.dart';

/// Clears in-memory and local queued state when the signed-in user changes.
class AppSessionReset {
  AppSessionReset._();

  /// Synchronous — safe before showing the login screen.
  static void onSignOutImmediate() {
    AttendanceRepository.instance.resetForSignOut();
  }

  /// Slow I/O (FCM unsubscribe, local queues) — run after UI has switched.
  static Future<void> onSignOutDeferred({String? noticesDiskCacheUserKey}) async {
    await Future.wait<void>([
      DeviceStudentRegistrationLock.clearOnSignOut(),
      AttendanceLocalQueues.clearAllPending(),
      PushController.instance.resetForSignOut(),
      NotificationMaintenanceCoordinator.onSignedOut(),
      if (noticesDiskCacheUserKey != null &&
          noticesDiskCacheUserKey.trim().isNotEmpty)
        NoticesRepository.clearDiskCacheForUserKey(noticesDiskCacheUserKey),
    ]);
  }

  static Future<void> onSignOut({String? noticesDiskCacheUserKey}) async {
    onSignOutImmediate();
    await onSignOutDeferred(noticesDiskCacheUserKey: noticesDiskCacheUserKey);
  }
}
