#!/usr/bin/env bash
# Obtain Let's Encrypt cert for api.orion13.us and enable HTTPS.
# Run ON the server as root, after DNS A record points to this VPS.
#
# Prerequisite: api.orion13.us → 169.58.135.136 (verify: dig +short api.orion13.us)

set -euo pipefail

DOMAIN="${UPANEL_API_DOMAIN:-api.orion13.us}"
EMAIL="${UPANEL_LETSENCRYPT_EMAIL:-kiu-qa-department@orion13.us}"
APP_DIR="${UPANEL_APP_DIR:-/opt/upanel}"

cd "${APP_DIR}"

echo "Checking DNS for ${DOMAIN}..."
RESOLVED=$(dig +short "${DOMAIN}" | tail -1)
if [[ -z "${RESOLVED}" ]]; then
  echo "ERROR: ${DOMAIN} has no DNS A record yet." >&2
  echo "Add an A record: ${DOMAIN} → your VPS IP, wait 5–30 min, then re-run." >&2
  exit 1
fi
echo "  ${DOMAIN} → ${RESOLVED}"

echo "Installing certbot..."
apt-get update -qq
apt-get install -y -qq certbot

echo "Stopping nginx briefly for standalone cert issuance..."
docker compose -f docker-compose.prod.yml stop nginx

certbot certonly --standalone \
  -d "${DOMAIN}" \
  --non-interactive \
  --agree-tos \
  -m "${EMAIL}" \
  --preferred-challenges http

echo "Enabling HTTP→HTTPS redirect in nginx config..."
sed -i 's|# return 301 https://|return 301 https://|' config/nginx/upanel-docker.conf

echo "Starting full stack with TLS..."
docker compose -f docker-compose.prod.yml --env-file .env.production up -d

echo "Setting up cert auto-renewal..."
CRON_LINE="0 3 * * * certbot renew --quiet --pre-hook 'docker compose -f ${APP_DIR}/docker-compose.prod.yml stop nginx' --post-hook 'docker compose -f ${APP_DIR}/docker-compose.prod.yml start nginx'"
( crontab -l 2>/dev/null | grep -v certbot; echo "${CRON_LINE}" ) | crontab -

echo ""
echo "HTTPS ready: https://${DOMAIN}/api/health/"
echo "Update .env.production: PUBLIC_API_URL=https://${DOMAIN}"
