#!/usr/bin/env bash
# Build a signed release APK for sideloading / testing.
#
# Usage:
#   bash scripts/build-apk.sh
#   ONESIGNAL_APP_ID=your-uuid bash scripts/build-apk.sh
#
# Requires release signing: android/key.properties locally, or Cursor Cloud Agent
# secrets (see scripts/setup-android-signing.sh).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

bash scripts/setup-android-signing.sh

API_URL="${UPANEL_API_BASE_URL:-https://kiu.orion13.us}"
ONESIGNAL_ID="${ONESIGNAL_APP_ID:-882dcbec-c505-4c12-95c5-78da7e8ef25c}"
DART_DEFINES=(--dart-define="UPANEL_API_BASE_URL=${API_URL}" --dart-define="ONESIGNAL_APP_ID=${ONESIGNAL_ID}")

if [[ -n "${SENTRY_DSN:-}" ]]; then
  DART_DEFINES+=(--dart-define="SENTRY_DSN=${SENTRY_DSN}")
fi

flutter pub get
flutter build apk --release "${DART_DEFINES[@]}"

OUT="build/app/outputs/flutter-apk/app-release.apk"
VERSION="$(grep -E '^version:' pubspec.yaml | sed -E 's/version:[[:space:]]*([^+]+)\+([0-9]+)/\1-build\2/')"
DEST="/opt/cursor/artifacts/U-Panel-${VERSION}-release.apk"
mkdir -p /opt/cursor/artifacts
cp "$OUT" "$DEST"
echo ""
echo "Built: $OUT"
echo "Copy:  $DEST"
