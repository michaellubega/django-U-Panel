/// Compile-time build number (`--dart-define=APP_BUILD_NUMBER=...`).
/// Matches [pubspec.yaml] `version: x.y.z+BUILD` for web verification.
const String kAppBuildNumber = String.fromEnvironment(
  'APP_BUILD_NUMBER',
  defaultValue: '10',
);

const String kAppVersionLabel = String.fromEnvironment(
  'APP_VERSION_LABEL',
  defaultValue: '1.0.0',
);

String get appVersionDisplay => 'v$kAppVersionLabel+$kAppBuildNumber';
