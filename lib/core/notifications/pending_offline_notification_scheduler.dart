import 'package:shared_preferences/shared_preferences.dart';

import '../../features/attendance/data/attendance_offline_sync.dart';
import '../push/local_push_display.dart';
import 'local_notification_scheduler.dart';
import 'notification_ids.dart';

/// Shared prefs keys for pending-offline reminder timing.
class PendingOfflineReminderPrefs {
  PendingOfflineReminderPrefs._();

  static const fireAtKey = 'pending_offline_reminder_fire_at_ms';
  static const lastShownKey = 'pending_offline_last_reminder_ms';
}

/// Schedules a device-local reminder when offline attendance queues have work.
class PendingOfflineNotificationScheduler {
  PendingOfflineNotificationScheduler._();

  static const _reminderInterval = Duration(hours: 24);

  /// Call when new offline work is enqueued — resets the 24h reminder timer.
  static Future<void> onNewPendingWork() async {
    await _syncSchedule(resetTimer: true);
  }

  /// Call after uploads / queue drains — cancels reminder when nothing left.
  static Future<void> onQueuesChanged() async {
    await _syncSchedule(resetTimer: false);
  }

  static Future<void> _syncSchedule({required bool resetTimer}) async {
    if (!LocalNotificationScheduler.supported) return;

    final counts = await AttendanceOfflineSync.countPendingWork();
    final prefs = await SharedPreferences.getInstance();

    if (counts.total <= 0) {
      await LocalNotificationScheduler.cancel(
        NotificationIds.pendingOfflineReminder,
      );
      await prefs.remove(PendingOfflineReminderPrefs.fireAtKey);
      return;
    }

    final now = DateTime.now();
    var fireAt = now.add(_reminderInterval);
    if (!resetTimer) {
      final existingMs = prefs.getInt(PendingOfflineReminderPrefs.fireAtKey);
      if (existingMs != null) {
        final existing = DateTime.fromMillisecondsSinceEpoch(existingMs);
        if (existing.isAfter(now)) {
          fireAt = existing;
        }
      }
    }

    await LocalNotificationScheduler.schedule(
      id: NotificationIds.pendingOfflineReminder,
      title: 'Pending attendance needs internet',
      body:
          'You have ${counts.summaryLabel} saved on this device. '
          'Open U-Panel while online to upload.',
      when: fireAt,
    );
    await prefs.setInt(
      PendingOfflineReminderPrefs.fireAtKey,
      fireAt.millisecondsSinceEpoch,
    );
  }

  /// Used by background tasks and foreground coordinator backup checks.
  static Future<void> runBackgroundCheck() async {
    if (!LocalNotificationScheduler.supported) return;

    final counts = await AttendanceOfflineSync.countPendingWork();
    if (counts.total <= 0) {
      await onQueuesChanged();
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();
    final fireAtMs = prefs.getInt(PendingOfflineReminderPrefs.fireAtKey);
    final lastShownMs = prefs.getInt(PendingOfflineReminderPrefs.lastShownKey);

    final fireAtReached = fireAtMs != null &&
        !now.isBefore(DateTime.fromMillisecondsSinceEpoch(fireAtMs));
    final intervalElapsed = lastShownMs == null ||
        now.difference(DateTime.fromMillisecondsSinceEpoch(lastShownMs)) >=
            _reminderInterval;

    if (!(fireAtReached && intervalElapsed)) {
      await _syncSchedule(resetTimer: false);
      return;
    }

    await LocalNotificationScheduler.ensureReady();
    await localPushShow(
      id: NotificationIds.pendingOfflineBackground,
      title: 'Pending attendance needs internet',
      body:
          'You have ${counts.summaryLabel} saved on this device. '
          'Open U-Panel while online to upload.',
    );

    await prefs.setInt(
      PendingOfflineReminderPrefs.lastShownKey,
      now.millisecondsSinceEpoch,
    );
    final nextFire = now.add(_reminderInterval);
    await prefs.setInt(
      PendingOfflineReminderPrefs.fireAtKey,
      nextFire.millisecondsSinceEpoch,
    );
    await LocalNotificationScheduler.schedule(
      id: NotificationIds.pendingOfflineReminder,
      title: 'Pending attendance needs internet',
      body:
          'You have ${counts.summaryLabel} saved on this device. '
          'Open U-Panel while online to upload.',
      when: nextFire,
    );
  }

  static Future<void> cancelAll() async {
    await LocalNotificationScheduler.cancelMany([
      NotificationIds.pendingOfflineReminder,
      NotificationIds.pendingOfflineBackground,
    ]);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(PendingOfflineReminderPrefs.fireAtKey);
    await prefs.remove(PendingOfflineReminderPrefs.lastShownKey);
  }
}
