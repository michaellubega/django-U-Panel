#!/usr/bin/env bash
# Enable HTTPS for api.orion13.us via Cloudflare (recommended).
# Cloudflare terminates TLS; origin stays HTTP on port 80 (SSH keeps port 443).
#
# Run locally after DNS is configured, then on the server to apply env + redeploy.

set -euo pipefail

DOMAIN="${UPANEL_API_DOMAIN:-api.orion13.us}"
WEB_ORIGIN="${UPANEL_WEB_ORIGIN:-https://kiu.orion13.us}"
APP_DIR="${UPANEL_APP_DIR:-/opt/upanel}"
VPS_IP="${UPANEL_VPS_IP:-169.58.135.136}"

cat <<EOF

================================================================================
HTTPS setup for U-Panel (Cloudflare + GitHub Pages)
================================================================================

STEP 1 — Cloudflare DNS (orion13.us zone)
  Add record:
    Type: A
    Name: api
    Content: ${VPS_IP}
    Proxy: ON (orange cloud)

  SSL/TLS → Overview → Encryption mode: Flexible
    (Cloudflare HTTPS → your server HTTP port 80)

STEP 2 — GitHub Pages (kiu.orion13.us)
  Repo → Settings → Pages → Deploy from branch → gh-pages / (root)
  Custom domain: kiu.orion13.us (already in website/CNAME)

STEP 3 — Server .env.production (on Contabo)
  Append or update these lines:

    DJANGO_DEBUG=False
    DJANGO_ALLOWED_HOSTS=${DOMAIN},${VPS_IP},localhost,127.0.0.1
    PUBLIC_API_URL=https://${DOMAIN}
    CORS_ALLOWED_ORIGINS=${WEB_ORIGIN},https://${DOMAIN}
    CSRF_TRUSTED_ORIGINS=${WEB_ORIGIN},https://${DOMAIN}
    APP_RETURN_URL=${WEB_ORIGIN}/app/

STEP 4 — Deploy on server
    cd ${APP_DIR}
    git pull origin main
    bash scripts/contabo/deploy-web-on-server.sh

STEP 5 — Verify
    curl -sf https://${DOMAIN}/api/health/
    curl -sfI https://${DOMAIN}/app/ | head -1
    Open ${WEB_ORIGIN}/app/ and sign in

================================================================================
EOF

if [[ "${1:-}" == "--write-env-snippet" ]]; then
  cat <<ENV
DJANGO_DEBUG=False
DJANGO_ALLOWED_HOSTS=${DOMAIN},${VPS_IP},localhost,127.0.0.1
PUBLIC_API_URL=https://${DOMAIN}
CORS_ALLOWED_ORIGINS=${WEB_ORIGIN},https://${DOMAIN}
CSRF_TRUSTED_ORIGINS=${WEB_ORIGIN},https://${DOMAIN}
APP_RETURN_URL=${WEB_ORIGIN}/app/
ENV
fi
