import 'dart:async';

import 'package:flutter/foundation.dart';

import 'attendance_lesson_notification_scheduler.dart';
import 'background_notification_task_registry.dart';
import 'pending_offline_notification_scheduler.dart';

/// Starts mobile notification scheduling after sign-in.
class NotificationMaintenanceCoordinator {
  NotificationMaintenanceCoordinator._();

  static Future<void> onSignedIn() async {
    try {
      await BackgroundNotificationTaskRegistry.register();
      await PendingOfflineNotificationScheduler.onQueuesChanged();
      await AttendanceLessonNotificationScheduler.syncFromStore();
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('NotificationMaintenanceCoordinator.onSignedIn failed: $e');
        debugPrint('$st');
      }
    }
  }

  static Future<void> onSignedOut() async {
    await BackgroundNotificationTaskRegistry.cancel();
    await PendingOfflineNotificationScheduler.cancelAll();
    await AttendanceLessonNotificationScheduler.cancelAll();
  }

  static Future<void> onAttendanceStoreUpdated() async {
    unawaited(PendingOfflineNotificationScheduler.onQueuesChanged());
    unawaited(AttendanceLessonNotificationScheduler.syncFromStore());
  }
}
