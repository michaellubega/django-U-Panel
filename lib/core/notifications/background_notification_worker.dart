import 'package:flutter/foundation.dart';

import '../storage/attendance_local_queues.dart';
import 'attendance_lesson_notification_scheduler.dart';
import 'pending_offline_notification_scheduler.dart';

/// Notification maintenance runnable from foreground and Workmanager isolates.
class BackgroundNotificationWorker {
  BackgroundNotificationWorker._();

  static Future<void> runAll() async {
    try {
      await AttendanceLocalQueues.ensureInitialized();
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('BackgroundNotificationWorker: queue init failed: $e');
        debugPrint('$st');
      }
    }

    await PendingOfflineNotificationScheduler.runBackgroundCheck();
    await AttendanceLessonNotificationScheduler.resyncFromPersistedSnapshot();
  }
}
