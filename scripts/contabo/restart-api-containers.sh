#!/usr/bin/env bash
# Recreate API containers so they pick up .env.production changes.
# `docker compose restart` does NOT reload env_file — always use this after editing secrets.
#
# Usage on server:
#   bash scripts/contabo/restart-api-containers.sh

set -euo pipefail

APP_DIR="${UPANEL_APP_DIR:-/opt/upanel}"
cd "$APP_DIR"

COMPOSE=(docker compose -f docker-compose.prod.yml --env-file .env.production)

echo "==> Recreating web, worker, beat (reload .env.production)"
"${COMPOSE[@]}" up -d --force-recreate web worker beat

echo ""
echo "==> OneSignal env inside web container (values hidden)"
"${COMPOSE[@]}" exec -T web python - <<'PY'
import os

app_id = (os.environ.get("ONESIGNAL_APP_ID") or "").strip()
rest = (os.environ.get("ONESIGNAL_REST_API_KEY") or "").strip()
print(f"ONESIGNAL_APP_ID set: {bool(app_id)} ({len(app_id)} chars)")
print(f"ONESIGNAL_REST_API_KEY set: {bool(rest)} ({len(rest)} chars)")
PY

echo ""
echo "==> client-config"
sleep 2
curl -sf http://127.0.0.1/api/client-config/ | python3 -m json.tool 2>/dev/null || curl -sf http://127.0.0.1/api/client-config/
echo ""
