#!/usr/bin/env bash
# Materialize android/key.properties + keystore from Cursor Cloud Agent secrets.
#
# Add these as Runtime Secrets in Cursor → Cloud Agents → Secrets (never commit them):
#   ANDROID_KEYSTORE_BASE64  — base64 of your upload-keystore.jks (single line)
#   ANDROID_KEYSTORE_PASSWORD
#   ANDROID_KEY_PASSWORD     — optional; defaults to ANDROID_KEYSTORE_PASSWORD
#   ANDROID_KEY_ALIAS        — optional; defaults to "upload"
#
# On your Mac, encode the keystore:
#   base64 -i path/to/upload-keystore.jks | tr -d '\n' | pbcopy
#
# If android/key.properties and the keystore file already exist (local Mac build), this script is a no-op.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ANDROID_DIR="$ROOT/android"
APP_DIR="$ANDROID_DIR/app"
KEY_PROPS="$ANDROID_DIR/key.properties"

existing_store_file=""
if [[ -f "$KEY_PROPS" ]]; then
  existing_store_file="$(grep -E '^storeFile=' "$KEY_PROPS" | cut -d= -f2- | tr -d '\r' || true)"
  if [[ -n "$existing_store_file" && -f "$APP_DIR/$existing_store_file" ]]; then
    echo "Android signing already configured ($KEY_PROPS)."
    exit 0
  fi
fi

STORE_PASS="${ANDROID_KEYSTORE_PASSWORD:-}"
KEY_PASS="${ANDROID_KEY_PASSWORD:-$STORE_PASS}"
KEY_ALIAS="${ANDROID_KEY_ALIAS:-upload}"
KEYSTORE_B64="${ANDROID_KEYSTORE_BASE64:-}"
KEYSTORE_PATH="${ANDROID_KEYSTORE_PATH:-}"

if [[ -z "$STORE_PASS" ]]; then
  echo "ERROR: Set ANDROID_KEYSTORE_PASSWORD (and ANDROID_KEYSTORE_BASE64) in Cursor Cloud Agent secrets." >&2
  echo "See scripts/setup-android-signing.sh for setup instructions." >&2
  exit 1
fi

STORE_FILE="upload-keystore.jks"
DEST_KEYSTORE="$APP_DIR/$STORE_FILE"

if [[ -n "$KEYSTORE_B64" ]]; then
  printf '%s' "$KEYSTORE_B64" | tr -d '\n' | base64 -d >"$DEST_KEYSTORE"
elif [[ -n "$KEYSTORE_PATH" && -f "$KEYSTORE_PATH" ]]; then
  cp "$KEYSTORE_PATH" "$DEST_KEYSTORE"
else
  echo "ERROR: Set ANDROID_KEYSTORE_BASE64 or ANDROID_KEYSTORE_PATH." >&2
  exit 1
fi

cat >"$KEY_PROPS" <<EOF
storePassword=${STORE_PASS}
keyPassword=${KEY_PASS}
keyAlias=${KEY_ALIAS}
storeFile=${STORE_FILE}
EOF

chmod 600 "$KEY_PROPS" "$DEST_KEYSTORE"

echo "Configured Android release signing from environment secrets."
if command -v keytool >/dev/null 2>&1; then
  SHA256="$(
    keytool -list -v -keystore "$DEST_KEYSTORE" -alias "$KEY_ALIAS" \
      -storepass "$STORE_PASS" -keypass "$KEY_PASS" 2>/dev/null \
      | grep -i 'SHA256:' | head -1 | sed 's/.*SHA256: //' || true
  )"
  if [[ -n "$SHA256" ]]; then
    echo "Release certificate SHA-256: $SHA256"
    echo "(Should match your Play Console upload key fingerprint.)"
  fi
fi
