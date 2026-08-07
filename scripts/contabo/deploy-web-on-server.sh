#!/usr/bin/env bash
# Pull latest code, rebuild nginx (includes website/app), restart stack.
# Run ON the Contabo server as root:
#   ssh -p 443 -i ~/.ssh/id_ed25519 root@169.58.135.136
#   cd /opt/upanel && bash scripts/contabo/deploy-web-on-server.sh

set -euo pipefail

APP_DIR="${UPANEL_APP_DIR:-/opt/upanel}"
cd "${APP_DIR}"

echo "==> Pull latest main"
git fetch origin main
git checkout main
git pull origin main

if [[ ! -f website/app/index.html ]]; then
  echo "==> website/app missing on main — try gh-pages CI build"
  if git fetch origin gh-pages 2>/dev/null && git cat-file -e origin/gh-pages:app/index.html 2>/dev/null; then
    rm -rf website/app
    mkdir -p website/app
    git archive origin/gh-pages app | tar -x --strip-components=1 -C website/app
  fi
fi

if [[ ! -f website/app/index.html ]]; then
  echo "ERROR: website/app/index.html missing." >&2
  echo "Enable GitHub Pages (gh-pages branch) and wait for CI, or build web locally." >&2
  exit 1
fi

echo "==> Rebuild nginx image (embeds website/app) and restart stack"
docker compose -f docker-compose.prod.yml --env-file .env.production build nginx
docker compose -f docker-compose.prod.yml --env-file .env.production up -d --build web worker beat nginx

echo "==> Health checks (wait for containers)"
sleep 5
curl -sf http://127.0.0.1/api/health/ && echo " API OK"
APP_STATUS=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/app/)
echo " /app/ HTTP ${APP_STATUS}"
if [[ "${APP_STATUS}" != "200" ]]; then
  echo "ERROR: /app/ did not return 200. Check: docker compose logs nginx" >&2
  exit 1
fi

echo ""
echo "Web app (HTTP):  http://169.58.135.136/app/"
echo "After Cloudflare: https://api.orion13.us/app/"
echo "GitHub Pages:     https://kiu.orion13.us/app/ (enable gh-pages branch in repo Settings)"
echo "Run: bash scripts/contabo/setup-cloudflare-https.sh"
