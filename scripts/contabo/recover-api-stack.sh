#!/usr/bin/env bash
# Bring the API back up after a 502 (web container down or stale).
set -euo pipefail

APP_DIR="${UPANEL_APP_DIR:-/opt/upanel}"
cd "$APP_DIR"

COMPOSE=(docker compose -f docker-compose.prod.yml --env-file .env.production)

echo "==> Pull latest deploy scripts"
git fetch origin main
git checkout main
git pull origin main

echo ""
echo "==> Ensure core env keys exist"
bash scripts/contabo/fix-production-env.sh || true

echo ""
echo "==> Start database + redis, then rebuild and recreate API containers"
"${COMPOSE[@]}" up -d db redis
"${COMPOSE[@]}" build --no-cache web worker beat
"${COMPOSE[@]}" up -d --force-recreate web worker beat

echo ""
echo "==> Wait for API health"
for i in $(seq 1 30); do
  if curl -sf http://127.0.0.1/api/health/ >/dev/null 2>&1; then
    echo "API healthy after ${i} attempt(s)"
    curl -s http://127.0.0.1/api/health/
    echo ""
    curl -s http://127.0.0.1/api/client-config/
    echo ""
    exit 0
  fi
  echo "  waiting... (${i}/30)"
  sleep 2
done

echo "ERROR: API still not healthy. Run: bash scripts/contabo/diagnose-api-502.sh" >&2
"${COMPOSE[@]}" logs web --tail 100 >&2 || true
exit 1
