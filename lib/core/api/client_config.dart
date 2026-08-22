import 'package:flutter/foundation.dart';

import 'api_client.dart';
import 'api_config.dart';

bool _clientConfigLoaded = false;

/// Loads public client settings from the API (e.g. OneSignal App ID for push).
Future<void> loadClientConfig() async {
  if (_clientConfigLoaded || isOneSignalConfigured) return;
  try {
    final data = await ApiClient.instance.getJson('/api/client-config/');
    final appId = (data?['onesignal_app_id'] as String?)?.trim() ?? '';
    if (appId.isNotEmpty) {
      setRuntimeOneSignalAppId(appId);
    }
  } catch (e, st) {
    if (kDebugMode) {
      debugPrint('loadClientConfig failed: $e\n$st');
    }
  } finally {
    _clientConfigLoaded = true;
  }
}
