import '../../features/attendance/attendance_schedule_utils.dart';
import '../../features/attendance/models/attendance_models.dart';
import '../auth/auth_repository.dart';
import '../auth/user_role.dart';
import 'lesson_reminder_snapshot.dart';
import 'local_notification_scheduler.dart';
import 'notification_ids.dart';

/// Device-local reminders when scheduled lessons start (lecturer) or are
/// overdue for QA (1:30 after lesson time). Works when the app is killed.
class AttendanceLessonNotificationScheduler {
  AttendanceLessonNotificationScheduler._();

  static const _lookaheadDays = 7;

  static Future<void> syncFromStore() async {
    if (!LocalNotificationScheduler.supported) return;
    final auth = AuthRepository.instance;
    if (!auth.isLoggedIn || !auth.roleCheckDone) return;

    final role = auth.resolvedRole;
    final uid = auth.currentUserId?.trim();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final endDay = today.add(const Duration(days: _lookaheadDays));

    final scheduled = <PersistedLessonReminder>[];
    final activeIds = <int>{};

    for (var day = today;
        !day.isAfter(endDay);
        day = day.add(const Duration(days: 1))) {
      for (final list in AttendanceStore.lists) {
        if (list.status == AttendanceListStatus.closed) continue;
        if (!AttendanceScheduleUtils.isListScheduledOnDate(list, day)) {
          continue;
        }
        if (AttendanceScheduleUtils.listHasSessionOnLocalDay(list.id, day)) {
          continue;
        }

        final start = AttendanceScheduleUtils.scheduledStartOnDate(list, day);
        if (start == null) continue;

        final title = list.displayTitle;
        final classLine = list.listLabelLine;
        final timeLabel = list.time.trim();

        if (role == UserRole.lecturer &&
            uid != null &&
            uid.isNotEmpty &&
            list.lecturerUid?.trim() == uid &&
            start.isAfter(now)) {
          final id = NotificationIds.lessonLecturer(list.id, day);
          activeIds.add(id);
          scheduled.add(
            PersistedLessonReminder(
              id: id,
              fireAtIso: start.toIso8601String(),
              title: 'Start attendance: $title',
              body:
                  'Your class ($classLine) is scheduled for $timeLabel. '
                  'Open U-Panel and start the attendance session.',
            ),
          );
        }

        if (role.hasStaffOperationalAccess) {
          final qaAt = start.add(AttendanceScheduleUtils.qaEscalationAfter);
          if (qaAt.isAfter(now)) {
            final id = NotificationIds.lessonQa(list.id, day);
            activeIds.add(id);
            final who = list.whoTaught.trim().isNotEmpty
                ? list.whoTaught.trim()
                : 'the lecturer';
            scheduled.add(
              PersistedLessonReminder(
                id: id,
                fireAtIso: qaAt.toIso8601String(),
                title: 'Attendance not started: $title',
                body:
                    '$who has not opened attendance for $classLine '
                    '(scheduled $timeLabel). It is 1 hour 30 minutes past '
                    'lesson time — QA can start the session in the app.',
              ),
            );
          }
        }
      }
    }

    final previousIds = await loadPreviousLessonReminderIds();
    for (final oldId in previousIds.difference(activeIds)) {
      await LocalNotificationScheduler.cancel(oldId);
    }

    for (final reminder in scheduled) {
      final when = DateTime.tryParse(reminder.fireAtIso);
      if (when == null || !when.isAfter(now)) continue;
      await LocalNotificationScheduler.schedule(
        id: reminder.id,
        title: reminder.title,
        body: reminder.body,
        when: when,
      );
    }

    await persistLessonReminders(scheduled);
  }

  /// Re-applies persisted lesson reminders after reboot / background wake.
  static Future<void> resyncFromPersistedSnapshot() async {
    if (!LocalNotificationScheduler.supported) return;
    final items = await loadPersistedLessonReminders();
    if (items.isEmpty) return;

    final now = DateTime.now();
    for (final reminder in items) {
      final when = DateTime.tryParse(reminder.fireAtIso);
      if (when == null || !when.isAfter(now)) continue;
      await LocalNotificationScheduler.schedule(
        id: reminder.id,
        title: reminder.title,
        body: reminder.body,
        when: when,
      );
    }
  }

  static Future<void> cancelAll() async {
    final ids = await loadPreviousLessonReminderIds();
    await LocalNotificationScheduler.cancelMany(ids);
    await clearLessonReminderSnapshot();
  }
}
