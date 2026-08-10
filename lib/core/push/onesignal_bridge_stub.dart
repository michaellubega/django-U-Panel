/// No-op OneSignal bridge (desktop / unconfigured builds).
Future<void> bridgeInitOneSignal({
  void Function(Map<String, dynamic>)? onOpened,
  void Function(Map<String, dynamic>)? onForeground,
  void Function()? onSubscriptionChanged,
}) async {}

Future<String?> bridgeGetPlayerId() async => null;

Future<void> bridgeSetTags(Map<String, String> tags) async {}

Future<void> bridgeLogoutOneSignal() async {}

bool get bridgeOneSignalSupported => false;
