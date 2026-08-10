#!/usr/bin/env bash
# Pull latest code, rebuild nginx (includes website/app), restart stack.
# Run ON the Contabo server as root:
#   ssh -p 443 -i ~/.ssh/id_ed25519 root@169.58.135.136
#   cd /opt/upanel && bash scripts/contabo/deploy-web-on-server.sh

set -euo pipefail

APP_DIR="${UPANEL_APP_DIR:-/opt/upanel}"

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

echo "==> Pull latest main"
git fetch origin main
git checkout main
git pull origin main

# Prefer a fresh Flutter web build from gh-pages CI when available (website/app on
# main is often stale because it is not rebuilt on every lib/ merge).
if git fetch origin gh-pages 2>/dev/null && git cat-file -e origin/gh-pages:app/index.html 2>/dev/null; then
  echo "==> Sync website/app from origin/gh-pages (CI-built Flutter web)"
  rm -rf website/app
  mkdir -p website/app
  git archive origin/gh-pages app | tar -x --strip-components=1 -C website/app
elif command -v flutter >/dev/null 2>&1; then
  echo "==> gh-pages unavailable — build Flutter web locally"
  flutter pub get
  flutter build web --release \
    --dart-define=UPANEL_API_BASE_URL="${UPANEL_API_BASE_URL:-http://169.58.135.136}" \
    --base-href=/app/
  bash scripts/finalize-web-build.sh
  rm -rf website/app
  mkdir -p website/app
  cp -a build/web/. website/app/
else
  echo "WARN: Using committed website/app (may be stale). Install Flutter or enable gh-pages CI." >&2
fi

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
