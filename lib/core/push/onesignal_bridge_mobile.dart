import 'package:onesignal_flutter/onesignal_flutter.dart';

import '../api/api_config.dart';

bool _ready = false;
void Function()? _onSubscriptionChanged;

bool get bridgeOneSignalSupported => isOneSignalConfigured;

Future<void> bridgeInitOneSignal({
  void Function(Map<String, dynamic>)? onOpened,
  void Function(Map<String, dynamic>)? onForeground,
  void Function()? onSubscriptionChanged,
}) async {
  if (!isOneSignalConfigured || _ready) return;
  _onSubscriptionChanged = onSubscriptionChanged;
  OneSignal.initialize(uPanelOneSignalAppId);
  await OneSignal.Notifications.requestPermission(true);

  OneSignal.Notifications.addClickListener((event) {
    final data = event.notification.additionalData;
    if (data == null || onOpened == null) return;
    onOpened(Map<String, dynamic>.from(data));
  });

  OneSignal.Notifications.addForegroundWillDisplayListener((event) {
    final data = event.notification.additionalData;
    if (data != null && onForeground != null) {
      onForeground(Map<String, dynamic>.from(data));
    }
    event.notification.display();
  });

  OneSignal.User.pushSubscription.addObserver((state) {
    final id = state.current.id?.trim();
    if (id == null || id.isEmpty) return;
    _onSubscriptionChanged?.call();
  });

  _ready = true;
}

Future<String?> bridgeGetPlayerId() async {
  if (!isOneSignalConfigured) return null;
  if (!_ready) {
    await bridgeInitOneSignal();
  }
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
  _onSubscriptionChanged = null;
}
