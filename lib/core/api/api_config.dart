/// REST API base URL for the Django backend.
///
/// Override at compile time:
/// `flutter run --dart-define=UPANEL_API_BASE_URL=http://192.168.1.10:8000`
///
/// On web, [web/index.html] may set `window.upanelApiBaseUrl` at runtime
/// (same-origin on Contabo, or https://api.orion13.us when configured).
import 'api_config_stub.dart' if (dart.library.js_interop) 'api_config_web.dart';

const String _kApiBaseUrlFromEnv = String.fromEnvironment(
  'UPANEL_API_BASE_URL',
  defaultValue: 'http://127.0.0.1:8000',
);

String get uPanelApiBaseUrl {
  final runtime = webRuntimeApiBaseUrl;
  if (runtime != null && runtime.isNotEmpty) {
    return runtime.endsWith('/') ? runtime.substring(0, runtime.length - 1) : runtime;
  }
  final v = _kApiBaseUrlFromEnv.trim();
  if (v.isEmpty) return 'http://127.0.0.1:8000';
  return v.endsWith('/') ? v.substring(0, v.length - 1) : v;
}

bool get isApiConfigured => uPanelApiBaseUrl.trim().isNotEmpty;

/// True when the API URL uses plain HTTP (blocked from HTTPS web pages).
bool get isInsecureApiBaseUrl =>
    uPanelApiBaseUrl.toLowerCase().startsWith('http://');

/// Compile-time Sentry DSN (`--dart-define=SENTRY_DSN=https://...`).
const String _kSentryDsnFromEnv = String.fromEnvironment('SENTRY_DSN');

String get uPanelSentryDsn => _kSentryDsnFromEnv.trim();

bool get isSentryConfigured => uPanelSentryDsn.isNotEmpty;

/// Default OneSignal App ID for U-Panel (public client identifier).
const String kDefaultOneSignalAppId = '882dcbec-c505-4c12-95c5-78da7e8ef25c';

/// Compile-time OneSignal App ID (`--dart-define=ONESIGNAL_APP_ID=...`).
const String _kOneSignalAppIdFromEnv = String.fromEnvironment('ONESIGNAL_APP_ID');

String _runtimeOneSignalAppId = '';

/// Set from [loadClientConfig] when the API exposes a OneSignal App ID.
void setRuntimeOneSignalAppId(String value) {
  final trimmed = value.trim();
  if (trimmed.isNotEmpty) {
    _runtimeOneSignalAppId = trimmed;
  }
}

String get uPanelOneSignalAppId {
  final compiled = _kOneSignalAppIdFromEnv.trim();
  if (compiled.isNotEmpty) return compiled;
  if (_runtimeOneSignalAppId.isNotEmpty) return _runtimeOneSignalAppId;
  return kDefaultOneSignalAppId;
}

bool get isOneSignalConfigured => uPanelOneSignalAppId.isNotEmpty;
