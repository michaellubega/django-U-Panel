#!/usr/bin/env bash
# Diagnose API 502 errors on the Contabo VPS.
set -euo pipefail

APP_DIR="${UPANEL_APP_DIR:-/opt/upanel}"
cd "$APP_DIR"

COMPOSE=(docker compose -f docker-compose.prod.yml --env-file .env.production)

echo "==> Container status"
"${COMPOSE[@]}" ps

echo ""
echo "==> Local HTTP checks"
for path in /api/health/ /api/client-config/ /app/; do
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1${path}" || echo "000")
  echo "  ${path} -> HTTP ${code}"
done

echo ""
echo "==> web container logs (last 80 lines)"
"${COMPOSE[@]}" logs web --tail 80 2>&1 || true

echo ""
echo "==> worker container logs (last 30 lines)"
"${COMPOSE[@]}" logs worker --tail 30 2>&1 || true

echo ""
echo "==> OneSignal env present (lengths only)"
"${COMPOSE[@]}" exec -T web python - <<'PY' 2>/dev/null || echo "  (web container not running)"
import os
for key in ("ONESIGNAL_APP_ID", "ONESIGNAL_REST_API_KEY", "DATABASE_URL"):
    val = (os.environ.get(key) or "").strip()
    print(f"  {key}: {len(val)} chars")
PY
