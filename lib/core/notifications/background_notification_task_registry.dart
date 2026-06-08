import 'package:flutter/foundation.dart';
import 'package:workmanager/workmanager.dart';

/// Workmanager task names — must match [callbackDispatcher] switch cases.
class BackgroundNotificationTasks {
  BackgroundNotificationTasks._();

  static const uniqueName = 'u_panel_notification_maintenance';
  static const taskName = 'uPanelNotificationMaintenance';
}

/// Registers periodic background notification maintenance (Android / iOS).
class BackgroundNotificationTaskRegistry {
  BackgroundNotificationTaskRegistry._();

  static bool get supported =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  static Future<void> register() async {
    if (!supported) return;
    await Workmanager().registerPeriodicTask(
      BackgroundNotificationTasks.uniqueName,
      BackgroundNotificationTasks.taskName,
      frequency: const Duration(hours: 24),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    );
  }

  static Future<void> cancel() async {
    if (!supported) return;
    await Workmanager().cancelByUniqueName(BackgroundNotificationTasks.uniqueName);
  }
}
