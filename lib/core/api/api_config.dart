/// REST API base URL for the Django backend.
///
/// Override at compile time (either define works):
/// `flutter run -d <device-id> --dart-define=API_URL=https://api.kiu.orion13.us`
/// `flutter run --dart-define=UPANEL_API_BASE_URL=http://192.168.1.10:8000`
///
/// On web, [web/index.html] may set `window.upanelApiBaseUrl` at runtime
/// (same-origin on Contabo, or https://api.kiu.orion13.us when configured).
import 'api_config_stub.dart' if (dart.library.js_interop) 'api_config_web.dart';

const String _kApiBaseUrlFromEnv = String.fromEnvironment('UPANEL_API_BASE_URL');
const String _kApiUrlAliasFromEnv = String.fromEnvironment('API_URL');

const String kDefaultLocalApiBaseUrl = 'http://127.0.0.1:8000';

/// Prefer `UPANEL_API_BASE_URL`, then the `API_URL` alias used by device runs.
String compiledApiBaseUrlDefine({
  required String upanelApiBaseUrl,
  required String apiUrl,
}) {
  final primary = upanelApiBaseUrl.trim();
  if (primary.isNotEmpty) return primary;
  return apiUrl.trim();
}

String normalizeApiBaseUrl(
  String raw, {
  String fallback = kDefaultLocalApiBaseUrl,
}) {
  final v = raw.trim();
  if (v.isEmpty) return fallback;
  return v.endsWith('/') ? v.substring(0, v.length - 1) : v;
}

/// Web runtime origin wins so HTTPS pages stay same-origin; native uses dart-define.
String resolveUPanelApiBaseUrl({
  required String compiled,
  String? runtimeWeb,
  String fallback = kDefaultLocalApiBaseUrl,
}) {
  final runtime = runtimeWeb?.trim();
  if (runtime != null && runtime.isNotEmpty) {
    return normalizeApiBaseUrl(runtime, fallback: fallback);
  }
  return normalizeApiBaseUrl(compiled, fallback: fallback);
}

String get uPanelApiBaseUrl => resolveUPanelApiBaseUrl(
      compiled: compiledApiBaseUrlDefine(
        upanelApiBaseUrl: _kApiBaseUrlFromEnv,
        apiUrl: _kApiUrlAliasFromEnv,
      ),
      runtimeWeb: webRuntimeApiBaseUrl,
    );

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
