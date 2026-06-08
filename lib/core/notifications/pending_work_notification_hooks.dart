import 'dart:async';



import '../offline/pending_offline_coordinator.dart';

import 'pending_offline_notification_scheduler.dart';



/// Hooks offline queue writes to pending-work reminder scheduling.

void notifyPendingWorkEnqueued() {

  unawaited(PendingOfflineNotificationScheduler.onNewPendingWork());

  PendingOfflineCoordinator.instance.requestSync();

}



void notifyPendingWorkQueuesChanged() {

  unawaited(PendingOfflineNotificationScheduler.onQueuesChanged());

}


