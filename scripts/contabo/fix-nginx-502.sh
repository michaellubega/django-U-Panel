#!/usr/bin/env bash
# Fast recovery when /api/ returns 502 but the web container is healthy.
# Usually nginx cached a stale `web` container IP after recreate.
set -euo pipefail

APP_DIR="${UPANEL_APP_DIR:-/opt/upanel}"
cd "$APP_DIR"

COMPOSE=(docker compose -f docker-compose.prod.yml --env-file .env.production)

echo "==> Pull latest nginx config"
git fetch origin main
git checkout main
git pull origin main

echo ""
echo "==> Rebuild and recreate nginx"
"${COMPOSE[@]}" build nginx
"${COMPOSE[@]}" up -d --force-recreate nginx

echo ""
echo "==> Health check"
for i in $(seq 1 15); do
  if curl -sf http://127.0.0.1/api/health/ >/dev/null 2>&1; then
    echo "API healthy after ${i} attempt(s)"
    curl -s http://127.0.0.1/api/health/
    echo ""
    exit 0
  fi
  echo "  waiting... (${i}/15)"
  sleep 2
done

echo "ERROR: still unhealthy — run: bash scripts/contabo/diagnose-api-502.sh" >&2
exit 1
