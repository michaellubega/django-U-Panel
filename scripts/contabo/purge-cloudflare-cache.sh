#!/usr/bin/env bash
# Purge Cloudflare edge cache for the Flutter web app shell after deploy.
#
# Without this, Cloudflare can keep serving an old main.dart.js for hours
# even after deploy-web-on-server.sh updates the origin.
#
# Usage (on server or locally):
#   CLOUDFLARE_API_TOKEN=... CLOUDFLARE_ZONE_ID=... bash scripts/contabo/purge-cloudflare-cache.sh
#
# Or add to /opt/upanel/.env.production:
#   CLOUDFLARE_API_TOKEN=...
#   CLOUDFLARE_ZONE_ID=...

set -euo pipefail

WEB_ORIGIN="${UPANEL_WEB_ORIGIN:-https://kiu.orion13.us}"
TOKEN="${CLOUDFLARE_API_TOKEN:-}"
ZONE="${CLOUDFLARE_ZONE_ID:-}"

if [[ -f .env.production ]]; then
  # shellcheck disable=SC1091
  set -a
  source .env.production
  set +a
  TOKEN="${CLOUDFLARE_API_TOKEN:-$TOKEN}"
  ZONE="${CLOUDFLARE_ZONE_ID:-$ZONE}"
fi

if [[ -z "$TOKEN" || -z "$ZONE" ]]; then
  echo "WARN: CLOUDFLARE_API_TOKEN and CLOUDFLARE_ZONE_ID not set — skipping purge." >&2
  echo "      Purge manually: Cloudflare → Caching → Purge by URL:" >&2
  echo "        ${WEB_ORIGIN}/app/main.dart.js" >&2
  echo "        ${WEB_ORIGIN}/app/index.html" >&2
  exit 0
fi

ORIGIN="${WEB_ORIGIN%/}"
FILES=(
  "${ORIGIN}/app/main.dart.js"
  "${ORIGIN}/app/flutter_bootstrap.js"
  "${ORIGIN}/app/index.html"
  "${ORIGIN}/app/version.json"
  "${ORIGIN}/app/flutter_service_worker.js"
)

JSON_FILES=$(printf '"%s",' "${FILES[@]}")
JSON_FILES="[${JSON_FILES%,}]"

echo "==> Purging Cloudflare cache for ${#FILES[@]} app shell URLs"
RESP=$(curl -sf -X POST \
  "https://api.cloudflare.com/client/v4/zones/${ZONE}/purge_cache" \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  --data "{\"files\":${JSON_FILES}}")

if echo "$RESP" | grep -q '"success":true'; then
  echo "    Cloudflare purge OK"
else
  echo "ERROR: Cloudflare purge failed: $RESP" >&2
  exit 1
fi
