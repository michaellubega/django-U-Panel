#!/usr/bin/env bash
# Pull latest code and restart nginx with the Flutter web app at /app/.
# Run ON the Contabo server as root (or via SSH):
#   ssh -p 443 -i ~/.ssh/id_ed25519 root@169.58.135.136 'bash -s' < scripts/contabo/deploy-web-on-server.sh

set -euo pipefail

APP_DIR="${UPANEL_APP_DIR:-/opt/upanel}"
cd "${APP_DIR}"

echo "==> Pull latest main"
git fetch origin main
git checkout main
git pull origin main

if [[ ! -f website/app/index.html ]]; then
  echo "ERROR: website/app/index.html missing. Build web locally or wait for CI gh-pages." >&2
  exit 1
fi

echo "==> Restart stack (nginx serves website/app at /app/)"
docker compose -f docker-compose.prod.yml --env-file .env.production up -d --build web worker nginx

echo "==> Health checks"
sleep 3
curl -sf http://127.0.0.1/api/health/ && echo " API OK"
curl -sfI http://127.0.0.1/app/ | head -1

echo ""
echo "Web app: http://169.58.135.136/app/"
echo "API:     http://169.58.135.136/api/health/"
