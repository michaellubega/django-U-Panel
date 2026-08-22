import 'dart:async';

import 'app_connectivity.dart';

/// Runs [persistOnline] when the device can reach the network; falls back to
/// [persistOffline] only after a failed online attempt or no network interface.
Future<T> persistOnlineFirst<T>({
  required Future<T> Function() persistOnline,
  required Future<T> Function() persistOffline,
  Duration timeout = const Duration(seconds: 8),
  Duration reachabilityProbe = const Duration(seconds: 4),
}) async {
  final connectivity = AppConnectivity.instance;
  if (!connectivity.hasNetworkInterface || !connectivity.isOnline) {
    return persistOffline();
  }

  Future<T> tryOnline() => persistOnline().timeout(timeout);

  try {
    return await tryOnline();
  } on TimeoutException {
    // Slow path: confirm reachability once, then retry.
  } catch (_) {
    // Fall through to reachability check + retry.
  }

  try {
    if (await connectivity.ensureReachable(timeout: reachabilityProbe)) {
      return await tryOnline();
    }
  } catch (_) {}

  return persistOffline();
}
