import 'package:onesignal_flutter/onesignal_flutter.dart';

import '../api/api_config.dart';

bool _ready = false;

bool get bridgeOneSignalSupported => isOneSignalConfigured;

Future<void> bridgeInitOneSignal() async {
  if (!isOneSignalConfigured || _ready) return;
  OneSignal.initialize(uPanelOneSignalAppId);
  await OneSignal.Notifications.requestPermission(true);
  _ready = true;
}

Future<String?> bridgeGetPlayerId() async {
  if (!isOneSignalConfigured) return null;
  if (!_ready) await bridgeInitOneSignal();
  return OneSignal.User.pushSubscription.id;
}

Future<void> bridgeSetTags(Map<String, String> tags) async {
  if (!isOneSignalConfigured || tags.isEmpty) return;
  if (!_ready) await bridgeInitOneSignal();
  await OneSignal.User.addTags(tags);
}

Future<void> bridgeLogoutOneSignal() async {
  if (!_ready) return;
  await OneSignal.logout();
  _ready = false;
}
