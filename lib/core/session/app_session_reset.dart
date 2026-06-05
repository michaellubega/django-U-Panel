import '../push/push_controller.dart';
import '../storage/attendance_local_queues.dart';
import '../../features/attendance/data/attendance_repository.dart';

/// Clears in-memory and local queued state when the signed-in user changes.
class AppSessionReset {
  AppSessionReset._();

  /// Synchronous — safe before showing the login screen.
  static void onSignOutImmediate() {
    AttendanceRepository.instance.resetForSignOut();
  }

  /// Slow I/O (FCM unsubscribe, local queues) — run after UI has switched.
  static Future<void> onSignOutDeferred() async {
    await Future.wait<void>([
      AttendanceLocalQueues.clearAllPending(),
      PushController.instance.resetForSignOut(),
    ]);
  }

  static Future<void> onSignOut() async {
    onSignOutImmediate();
    await onSignOutDeferred();
  }
}
