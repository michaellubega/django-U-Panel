import 'package:flutter/foundation.dart';

import '../../../core/connectivity/app_connectivity.dart';
import 'campus_presence_repository.dart';
import 'pending_campus_presence_queue.dart';

/// Uploads locally queued KIU administrator campus check-ins when online.
class PendingCampusPresenceSync {
  PendingCampusPresenceSync._();

  static Future<void> drain() async {
    if (!AppConnectivity.instance.hasNetworkInterface) return;
    if (!await AppConnectivity.instance.ensureReachable()) return;

    final pending = await PendingCampusPresenceQueue.loadAll();
    if (pending.isEmpty) return;

    for (final entry in List<PendingCampusPresenceEntry>.from(pending)) {
      try {
        final ok = await CampusPresenceRepository.instance
            .uploadQueuedPresence(entry);
        if (ok) {
          await PendingCampusPresenceQueue.removeById(entry.id);
        }
      } catch (e, st) {
        if (kDebugMode) {
          debugPrint('PendingCampusPresenceSync: ${entry.id} failed: $e');
          debugPrint('$st');
        }
      }
    }
  }
}
