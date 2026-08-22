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
echo "==> Direct web container health (bypass nginx)"
WEB_CID="$("${COMPOSE[@]}" ps -q web 2>/dev/null | head -1)"
if [[ -n "$WEB_CID" ]]; then
  docker exec "$WEB_CID" python - <<'PY' 2>/dev/null || echo "  (python probe failed)"
import urllib.request
try:
    with urllib.request.urlopen("http://127.0.0.1:8000/api/health/", timeout=5) as r:
        print(f"  web:8000/api/health/ -> HTTP {r.status}")
except Exception as e:
    print(f"  web:8000/api/health/ -> ERROR {e}")
PY
else
  echo "  (no web container id)"
fi

echo ""
echo "==> nginx -> web connectivity"
NGINX_CID="$("${COMPOSE[@]}" ps -q nginx 2>/dev/null | head -1)"
if [[ -n "$NGINX_CID" ]]; then
  docker exec "$NGINX_CID" wget -q -S -O /dev/null http://web:8000/api/health/ 2>&1 \
    | awk '/HTTP\// {print "  " $0}' | head -1 \
    || echo "  nginx cannot reach web:8000 (stale upstream IP — recreate nginx)"
else
  echo "  (no nginx container id)"
fi

echo ""
echo "==> web container inspect (state / exit code)"
"${COMPOSE[@]}" ps web
docker inspect --format '{{.State.Status}} exit={{.State.ExitCode}} error={{.State.Error}}' \
  "$("${COMPOSE[@]}" ps -q web 2>/dev/null | head -1)" 2>/dev/null || true

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
