/// REST API base URL for the Django backend.
///
/// Override at compile time:
/// `flutter run --dart-define=UPANEL_API_BASE_URL=http://192.168.1.10:8000`
const String _kApiBaseUrlFromEnv = String.fromEnvironment(
  'UPANEL_API_BASE_URL',
  defaultValue: 'http://127.0.0.1:8000',
);

String get uPanelApiBaseUrl {
  final v = _kApiBaseUrlFromEnv.trim();
  if (v.isEmpty) return 'http://127.0.0.1:8000';
  return v.endsWith('/') ? v.substring(0, v.length - 1) : v;
}

bool get isApiConfigured => uPanelApiBaseUrl.trim().isNotEmpty;

/// True when the compile-time API URL uses plain HTTP (blocked from HTTPS web pages).
bool get isInsecureApiBaseUrl =>
    uPanelApiBaseUrl.toLowerCase().startsWith('http://');

/// Compile-time Sentry DSN (`--dart-define=SENTRY_DSN=https://...`).
const String _kSentryDsnFromEnv = String.fromEnvironment('SENTRY_DSN');

String get uPanelSentryDsn => _kSentryDsnFromEnv.trim();

bool get isSentryConfigured => uPanelSentryDsn.isNotEmpty;

/// Compile-time OneSignal App ID (`--dart-define=ONESIGNAL_APP_ID=...`).
const String _kOneSignalAppIdFromEnv = String.fromEnvironment('ONESIGNAL_APP_ID');

String get uPanelOneSignalAppId => _kOneSignalAppIdFromEnv.trim();

bool get isOneSignalConfigured => uPanelOneSignalAppId.isNotEmpty;
