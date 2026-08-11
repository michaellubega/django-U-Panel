import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:onesignal_flutter/onesignal_flutter.dart';

import '../api/api_config.dart';

bool _sdkInitialized = false;
bool _handlersAttached = false;
bool _integrationDialogShown = false;
void Function()? _onSubscriptionChanged;
void Function(dynamic state)? _integrationObserverHolder;

bool get oneSignalImplSupported => isOneSignalConfigured;

void oneSignalImplInitializeSdk() {
  if (_sdkInitialized || !isOneSignalConfigured) return;
  if (kDebugMode) {
    OneSignal.Debug.setLogLevel(OSLogLevel.verbose);
  }
  OneSignal.initialize(uPanelOneSignalAppId);
  _sdkInitialized = true;
}

Future<void> oneSignalImplAttachHandlers({
  void Function(Map<String, dynamic>)? onOpened,
  void Function(Map<String, dynamic>)? onForeground,
  void Function()? onSubscriptionChanged,
}) async {
  if (!isOneSignalConfigured || _handlersAttached) return;
  oneSignalImplInitializeSdk();
  _onSubscriptionChanged = onSubscriptionChanged;

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

  _handlersAttached = true;
}

void oneSignalImplSetupIntegrationVerification(
  void Function(void Function() onRequestPermission) showDialog,
) {
  if (!isOneSignalConfigured) return;
  oneSignalImplInitializeSdk();

  void maybePrompt(String? subscriptionId) {
    if (!_isRegisteredSubscriptionId(subscriptionId) || _integrationDialogShown) {
      return;
    }
    _integrationDialogShown = true;
    showDialog(() {
      unawaited(OneSignal.Notifications.requestPermission(true));
    });
  }

  _integrationObserverHolder ??= (state) {
    maybePrompt(state.current.id);
  };
  OneSignal.User.pushSubscription.addObserver(_integrationObserverHolder!);
  maybePrompt(OneSignal.User.pushSubscription.id);
}

Future<String?> oneSignalImplGetPlayerId() async {
  if (!isOneSignalConfigured) return null;
  oneSignalImplInitializeSdk();
  return OneSignal.User.pushSubscription.id;
}

Future<void> oneSignalImplLogin(String externalUserId) async {
  if (!isOneSignalConfigured) return;
  oneSignalImplInitializeSdk();
  OneSignal.login(externalUserId);
}

Future<void> oneSignalImplSetTags(Map<String, String> tags) async {
  if (!isOneSignalConfigured || tags.isEmpty) return;
  oneSignalImplInitializeSdk();
  await OneSignal.User.addTags(tags);
}

Future<void> oneSignalImplLogout() async {
  if (!_sdkInitialized) return;
  await OneSignal.logout();
  // Keep handlers and subscription observer — PushController.initialize() is
  // idempotent and must still receive subscription changes after re-login.
}

Future<bool> oneSignalImplRequestPermission() {
  oneSignalImplInitializeSdk();
  return OneSignal.Notifications.requestPermission(true);
}

bool _isRegisteredSubscriptionId(String? id) =>
    id != null && id.isNotEmpty && !id.startsWith('local-');
