#!/usr/bin/env bash
# Pull latest code, sync Flutter web bundle, rebuild nginx (embeds website/app), restart stack.
#
# IMPORTANT: `docker compose up -d --build` alone does NOT update /app/main.dart.js.
# Nginx bakes website/app into its image at build time — run THIS script after every merge.
#
# Run ON the Contabo server as root:
#   ssh -p 443 -i ~/.ssh/id_ed25519 root@169.58.135.136
#   cd /opt/upanel && bash scripts/contabo/deploy-web-on-server.sh

set -euo pipefail

APP_DIR="${UPANEL_APP_DIR:-/opt/upanel}"
COMPOSE=(docker compose -f docker-compose.prod.yml --env-file .env.production)
# Bundle grew after PR #22 (Aug 2026). Smaller files are the pre-fix Aug 8 build.
MIN_BUNDLE_BYTES=5329000

bundle_sha() {
  if [[ -f website/app/main.dart.js ]]; then
    sha256sum website/app/main.dart.js | awk '{print $1}'
  fi
}

bundle_bytes() {
  if [[ -f website/app/main.dart.js ]]; then
    wc -c < website/app/main.dart.js | tr -d ' '
  else
    echo 0
  fi
}

describe_bundle() {
  if [[ -f website/app/main.dart.js ]]; then
    ls -la website/app/main.dart.js
    echo "    sha256=$(bundle_sha) bytes=$(bundle_bytes)"
  else
    echo "    (missing website/app/main.dart.js)"
  fi
}

if [[ ! -d "${APP_DIR}/.git" ]]; then
  echo "ERROR: ${APP_DIR} is not a git repository." >&2
  echo "" >&2
  echo "Run the one-time bootstrap (preserves .env.production):" >&2
  echo "  curl -fsSL https://raw.githubusercontent.com/michaellubega/django-U-Panel/main/scripts/contabo/bootstrap-server.sh | bash" >&2
  echo "" >&2
  echo "Or manually:" >&2
  echo "  bash scripts/contabo/bootstrap-server.sh" >&2
  exit 1
fi

cd "${APP_DIR}"

echo "==> Git state before deploy"
git log -1 --oneline
echo "==> website/app before sync"
describe_bundle
OLD_SHA="$(bundle_sha)"

echo "==> Pull latest main"
git fetch origin main
git checkout main
if git rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1; then
  echo "    Aborting in-progress merge (website/app is re-synced from gh-pages below)"
  git merge --abort
fi
# website/app is replaced from gh-pages on every deploy; local edits must not block pulls.
git reset --hard origin/main
echo "    now at: $(git log -1 --oneline)"

sync_from_gh_pages() {
  if git fetch origin gh-pages 2>/dev/null && git cat-file -e origin/gh-pages:app/index.html 2>/dev/null; then
    echo "==> Sync website/app from origin/gh-pages (CI-built Flutter web)"
    rm -rf website/app
    mkdir -p website/app
    git archive origin/gh-pages app | tar -x --strip-components=1 -C website/app
    return 0
  fi
  return 1
}

# Prefer a fresh Flutter web build from gh-pages CI when available (website/app on
# main is often stale because it is not rebuilt on every lib/ merge).
if ! sync_from_gh_pages; then
  if command -v flutter >/dev/null 2>&1; then
    echo "==> gh-pages unavailable — build Flutter web locally"
    flutter pub get
    BUILD_NUM="$(grep -E '^version:' pubspec.yaml | sed -E 's/.*\+([0-9]+).*/\1/')"
    VERSION_LABEL="$(grep -E '^version:' pubspec.yaml | sed -E 's/version: ([0-9.]+).*/\1/')"
    flutter build web --release \
      --dart-define=UPANEL_API_BASE_URL="${UPANEL_API_BASE_URL:-http://169.58.135.136}" \
      --dart-define=APP_BUILD_NUMBER="${BUILD_NUM}" \
      --dart-define=APP_VERSION_LABEL="${VERSION_LABEL}" \
      --base-href=/app/
    bash scripts/finalize-web-build.sh
    rm -rf website/app
    mkdir -p website/app
    cp -a build/web/. website/app/
  else
    echo "WARN: Using committed website/app (may be stale). Install Flutter or enable gh-pages CI." >&2
  fi
fi

if [[ ! -f website/app/index.html ]]; then
  echo "==> website/app missing — retry gh-pages CI build"
  sync_from_gh_pages || true
fi

if [[ ! -f website/app/index.html ]]; then
  echo "ERROR: website/app/index.html missing." >&2
  echo "Enable GitHub Pages (gh-pages branch) and wait for CI, or build web locally." >&2
  exit 1
fi

NEW_SHA="$(bundle_sha)"
NEW_BYTES="$(bundle_bytes)"
echo "==> website/app after sync"
describe_bundle

if [[ "${NEW_BYTES}" -lt "${MIN_BUNDLE_BYTES}" ]]; then
  echo "ERROR: main.dart.js is only ${NEW_BYTES} bytes (expected >= ${MIN_BUNDLE_BYTES})." >&2
  echo "The server still has the Aug 8 bundle. Check gh-pages CI or run a local flutter build." >&2
  exit 1
fi

NGINX_BUILD_FLAGS=()
if [[ -n "${OLD_SHA}" && "${OLD_SHA}" != "${NEW_SHA}" ]]; then
  echo "==> Bundle changed — forcing nginx rebuild without Docker cache"
  NGINX_BUILD_FLAGS=(--no-cache)
elif [[ -z "${OLD_SHA}" ]]; then
  NGINX_BUILD_FLAGS=(--no-cache)
fi

echo "==> Rebuild nginx image (embeds website/app) and restart stack"
"${COMPOSE[@]}" build "${NGINX_BUILD_FLAGS[@]}" nginx
"${COMPOSE[@]}" up -d --build web worker beat nginx

echo "==> Health checks (wait for containers)"
sleep 5
curl -sf http://127.0.0.1/api/health/ && echo " API OK"
APP_STATUS=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/app/)
echo " /app/ HTTP ${APP_STATUS}"
if [[ "${APP_STATUS}" != "200" ]]; then
  echo "ERROR: /app/ did not return 200. Check: docker compose logs nginx" >&2
  exit 1
fi

ASSETLINKS_STATUS=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/.well-known/assetlinks.json)
echo " /.well-known/assetlinks.json HTTP ${ASSETLINKS_STATUS}"
if [[ "${ASSETLINKS_STATUS}" != "200" ]]; then
  echo "ERROR: /.well-known/assetlinks.json did not return 200 (required for Android App Links)." >&2
  exit 1
fi

DOWNLOAD_STATUS=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/download/)
echo " /download/ HTTP ${DOWNLOAD_STATUS}"
if [[ "${DOWNLOAD_STATUS}" != "200" ]]; then
  echo "ERROR: /download/ did not return 200. Rebuild nginx after website/ changes." >&2
  exit 1
fi

ROOT_LOCATION=$(curl -sI http://127.0.0.1/ | tr -d '\r' | awk -F': ' 'tolower($1)=="location"{print $2}' | tail -1)
echo " / redirect Location: ${ROOT_LOCATION:-?}"
if [[ "${ROOT_LOCATION}" != *"/download/"* ]]; then
  echo "ERROR: / should redirect to /download/ (got: ${ROOT_LOCATION:-none})." >&2
  exit 1
fi

APK_STATUS=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/download/releases.json)
echo " /download/releases.json HTTP ${APK_STATUS}"
if [[ "${APK_STATUS}" != "200" ]]; then
  echo "ERROR: /download/releases.json did not return 200." >&2
  exit 1
fi
if ! grep -q playStoreUrl website/releases.json; then
  echo "ERROR: releases.json missing android.playStoreUrl (Play Store link required)." >&2
  exit 1
fi

WIN_INSTALLER="$(python3 - <<'PY'
import json, urllib.parse
from pathlib import Path
data = json.loads(Path("website/releases.json").read_text(encoding="utf-8-sig"))
url = (data.get("windows") or {}).get("file") or ""
name = urllib.parse.unquote(urllib.parse.urlparse(url).path.rsplit("/", 1)[-1])
print(name or "")
PY
)"
if [[ -n "${WIN_INSTALLER}" ]]; then
  WIN_STATUS=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1/downloads/${WIN_INSTALLER}")
  echo " /downloads/${WIN_INSTALLER} HTTP ${WIN_STATUS}"
  if [[ "${WIN_STATUS}" != "200" ]]; then
    echo "WARN: Windows installer returned HTTP ${WIN_STATUS}. Run scripts/prepare-download-site.ps1 and redeploy." >&2
  fi
else
  echo "WARN: No Windows installer URL in website/releases.json" >&2
fi

PRIVACY_STATUS=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/privacy.html)
echo " /privacy.html HTTP ${PRIVACY_STATUS}"
if [[ "${PRIVACY_STATUS}" != "200" ]]; then
  echo "ERROR: /privacy.html did not return 200 (required for Play Store)." >&2
  exit 1
fi

DELETE_ACCOUNT_STATUS=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/delete-account.html)
echo " /delete-account.html HTTP ${DELETE_ACCOUNT_STATUS}"
if [[ "${DELETE_ACCOUNT_STATUS}" != "200" ]]; then
  echo "ERROR: /delete-account.html did not return 200 (required for Play Store)." >&2
  exit 1
fi

SERVED_BYTES=$(curl -sI http://127.0.0.1/app/main.dart.js | tr -d '\r' | awk -F': ' 'tolower($1)=="content-length"{print $2}' | tail -1)
SERVED_LM=$(curl -sI http://127.0.0.1/app/main.dart.js | tr -d '\r' | awk -F': ' 'tolower($1)=="last-modified"{print $2}' | tail -1)
echo "==> Served main.dart.js: last-modified=${SERVED_LM:-?} content-length=${SERVED_BYTES:-?}"
echo "    Local main.dart.js: bytes=${NEW_BYTES}"

if [[ -n "${SERVED_BYTES}" && "${SERVED_BYTES}" != "${NEW_BYTES}" ]]; then
  echo "ERROR: nginx is still serving an old bundle (${SERVED_BYTES} bytes != ${NEW_BYTES})." >&2
  echo "Try: docker compose -f docker-compose.prod.yml --env-file .env.production build --no-cache nginx" >&2
  echo "     docker compose -f docker-compose.prod.yml --env-file .env.production up -d --force-recreate nginx" >&2
  exit 1
fi

if [[ -f website/app/version.json ]]; then
  echo "==> Deployed web build: $(cat website/app/version.json)"
fi

echo "==> Purge Cloudflare edge cache (prevents stale main.dart.js for up to 4h)"
bash scripts/contabo/purge-cloudflare-cache.sh || true

# Verify Cloudflare is serving the new bundle (HTTPS can remain stale).
HTTPS_BYTES=$(curl -sI https://kiu.orion13.us/app/main.dart.js 2>/dev/null \
  | tr -d '\r' \
  | awk -F': ' 'tolower($1)=="content-length"{print $2}' \
  | tail -1)
echo "==> Cloudflare-served main.dart.js content-length: ${HTTPS_BYTES:-?} (expected ${NEW_BYTES})"
if [[ -n "${HTTPS_BYTES}" && "${HTTPS_BYTES}" != "${NEW_BYTES}" ]]; then
  echo "WARN: HTTPS still serving an older main.dart.js via Cloudflare." >&2
  echo "      Cloudflare purge may have failed/been partial or require time to propagate." >&2
  echo "      Re-run purge manually, e.g.:" >&2
  echo "        bash scripts/contabo/purge-cloudflare-cache.sh" >&2
fi

echo ""
echo "Deploy OK. Verify from your machine:"
echo "  curl -sI http://169.58.135.136/app/main.dart.js | grep -i content-length"
echo "  curl -sI https://kiu.orion13.us/app/main.dart.js | grep -i content-length"
echo "  curl -sf https://kiu.orion13.us/.well-known/assetlinks.json | head"
echo "Expected content-length: ${NEW_BYTES}"
echo ""
echo "If the browser still shows the old UI:"
echo "  1. Hard refresh: Ctrl+Shift+R (or Cmd+Shift+R on Mac)"
echo "  2. Or: DevTools → Application → Clear site data for kiu.orion13.us"
echo "  3. Or: open in a private/incognito window"
echo ""
echo "Web app (HTTP):  http://169.58.135.136/app/"
echo "After Cloudflare: https://kiu.orion13.us/app/"
