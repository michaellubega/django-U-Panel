import 'package:flutter/foundation.dart';
import 'package:workmanager/workmanager.dart';

import 'background_notification_task_registry.dart';
import 'background_notification_worker.dart';

@pragma('vm:entry-point')
void uPanelBackgroundNotificationDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    if (kDebugMode) {
      debugPrint('Workmanager task: $task');
    }
    switch (task) {
      case BackgroundNotificationTasks.taskName:
      case Workmanager.iOSBackgroundTask:
        await BackgroundNotificationWorker.runAll();
        break;
      default:
        await BackgroundNotificationWorker.runAll();
        break;
    }
    return true;
  });
}

Future<void> initializeBackgroundNotificationTasks() async {
  if (!BackgroundNotificationTaskRegistry.supported) return;
  await Workmanager().initialize(uPanelBackgroundNotificationDispatcher);
}
