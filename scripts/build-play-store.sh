#!/usr/bin/env bash
# Build a signed Play Store app bundle (.aab).
#
# Usage:
#   bash scripts/build-play-store.sh
#   ONESIGNAL_APP_ID=your-uuid bash scripts/build-play-store.sh   # optional bake-in
#
# Without ONESIGNAL_APP_ID, the app loads it at runtime from GET /api/client-config/
# (server must have ONESIGNAL_APP_ID in .env.production).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

API_URL="${UPANEL_API_BASE_URL:-https://kiu.orion13.us}"
DART_DEFINES=(--dart-define="UPANEL_API_BASE_URL=${API_URL}")

if [[ -n "${ONESIGNAL_APP_ID:-}" ]]; then
  DART_DEFINES+=(--dart-define="ONESIGNAL_APP_ID=${ONESIGNAL_APP_ID}")
fi

if [[ -n "${SENTRY_DSN:-}" ]]; then
  DART_DEFINES+=(--dart-define="SENTRY_DSN=${SENTRY_DSN}")
fi

flutter pub get
flutter build appbundle --release "${DART_DEFINES[@]}"

OUT="build/app/outputs/bundle/release/app-release.aab"
VERSION="$(grep -E '^version:' pubspec.yaml | sed -E 's/version:[[:space:]]*([^+]+)\+([0-9]+)/\1-build\2/')"
DEST="/opt/cursor/artifacts/U-Panel-${VERSION}-release.aab"
mkdir -p /opt/cursor/artifacts
cp "$OUT" "$DEST"
echo ""
echo "Built: $OUT"
echo "Copy:  $DEST"
