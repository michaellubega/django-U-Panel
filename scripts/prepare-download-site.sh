#!/usr/bin/env bash
# Copies release builds into website/downloads and updates releases.json.
# Run from the project root after:
#   bash scripts/build-apk.sh
#
# Usage:
#   bash scripts/prepare-download-site.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SITE_DOMAIN="${UPANEL_SITE_DOMAIN:-https://kiu.orion13.us}"
WEB_APP_URL="${SITE_DOMAIN}/app/"

VERSION="$(grep -E '^version:' pubspec.yaml | sed -E 's/version:[[:space:]]*([^+]+)\+.*/\1/')"
BUILD="$(grep -E '^version:' pubspec.yaml | sed -E 's/version:[[:space:]]*[^+]+\+([0-9]+)/\1/')"
RELEASED_AT="$(date +%Y-%m-%d)"

WEBSITE="$ROOT/website"
DOWNLOADS="$WEBSITE/downloads"
mkdir -p "$DOWNLOADS"

format_size() {
  local bytes="$1"
  if (( bytes >= 1073741824 )); then
    awk -v b="$bytes" 'BEGIN { printf "%.2f GB\n", b/1073741824 }'
  elif (( bytes >= 1048576 )); then
    awk -v b="$bytes" 'BEGIN { printf "%.1f MB\n", b/1048576 }'
  elif (( bytes >= 1024 )); then
    awk -v b="$bytes" 'BEGIN { printf "%.0f KB\n", b/1024 }'
  else
    echo "${bytes} B"
  fi
}

APK_SRC="$ROOT/build/app/outputs/flutter-apk/app-release.apk"
APK_DST="$DOWNLOADS/U-Panel-${VERSION}-android.apk"
ANDROID_AVAILABLE="false"
ANDROID_SIZE=""

if [[ -f "$APK_SRC" ]]; then
  cp "$APK_SRC" "$APK_DST"
  ANDROID_AVAILABLE="true"
  ANDROID_SIZE="$(format_size "$(wc -c <"$APK_DST" | tr -d ' ')")"
  echo "Android APK copied for server hosting (not linked on download page): $APK_DST ($ANDROID_SIZE)"
elif [[ -f "$APK_DST" ]]; then
  ANDROID_AVAILABLE="true"
  ANDROID_SIZE="$(format_size "$(wc -c <"$APK_DST" | tr -d ' ')")"
  echo "Using existing Android APK (not linked on download page): $APK_DST ($ANDROID_SIZE)"
else
  echo "No APK build found (Play Store is the only Android install link on the site)." >&2
fi

WIN_DST="$DOWNLOADS/U-Panel-${VERSION}-windows-setup.exe"
WINDOWS_AVAILABLE="false"
WINDOWS_SIZE=""
if [[ -f "$WIN_DST" ]]; then
  WINDOWS_AVAILABLE="true"
  WINDOWS_SIZE="$(format_size "$(wc -c <"$WIN_DST" | tr -d ' ')")"
  echo "Windows: $WIN_DST ($WINDOWS_SIZE)"
fi

export SITE_DOMAIN WEB_APP_URL VERSION BUILD RELEASED_AT ANDROID_AVAILABLE ANDROID_SIZE WINDOWS_AVAILABLE WINDOWS_SIZE APK_DST WIN_DST
python3 <<'PY'
import json
import os
from pathlib import Path

site = os.environ["SITE_DOMAIN"]
web = os.environ["WEB_APP_URL"]
version = os.environ["VERSION"]
build = int(os.environ["BUILD"])
released = os.environ["RELEASED_AT"]
apk_name = Path(os.environ["APK_DST"]).name
win_name = Path(os.environ["WIN_DST"]).name

release = {
    "version": version,
    "build": build,
    "releasedAt": released,
    "hostBase": site,
    "ios": {
        "label": "iPhone & iPad",
        "status": "coming_soon",
        "webUrl": web,
        "message": "Native iOS app coming soon. Use the web app in Safari for now.",
    },
    "android": {
        "playStoreUrl": "https://play.google.com/store/apps/details?id=com.u_panel",
        "label": "Google Play",
        "minAndroid": "7.0 (Nougat)",
        "available": True,
    },
    "windows": {
        "file": f"{site}/downloads/{win_name}",
        "label": "Windows installer",
        "minWindows": "Windows 10 (64-bit)",
        "available": os.environ["WINDOWS_AVAILABLE"] == "true",
    },
    "web": {"url": web, "label": "Web app", "available": True},
}
if os.environ.get("WINDOWS_SIZE"):
    release["windows"]["size"] = os.environ["WINDOWS_SIZE"]

path = Path("website/releases.json")
path.write_text(json.dumps(release, indent=4) + "\n", encoding="utf-8")
print(f"Updated {path}")
PY

echo "Landing page: ${SITE_DOMAIN}/download/"
echo "Downloads:    ${SITE_DOMAIN}/downloads/"
