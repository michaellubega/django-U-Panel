/// Pure online/offline state used by [AppConnectivity.isOnline].
bool connectivityIsOnline({
  required bool hasNetworkInterface,
  required bool apiAttached,
  required bool initialized,
  required bool apiReachable,
  required int consecutiveProbeFailures,
  DateTime? lastSuccessfulProbe,
  Duration reachabilityGrace = const Duration(seconds: 8),
  int failuresBeforeOffline = 2,
  DateTime? now,
}) {
  if (!hasNetworkInterface) return false;
  if (!apiAttached || !initialized) return true;
  if (consecutiveProbeFailures >= failuresBeforeOffline) return false;
  if (apiReachable) return true;
  final at = lastSuccessfulProbe;
  final clock = now ?? DateTime.now();
  if (at != null && clock.difference(at) < reachabilityGrace) {
    return true;
  }
  return consecutiveProbeFailures < failuresBeforeOffline;
}
