#!/usr/bin/env bash
# Post-deploy server hardening and admin setup. Run ON the server as root.

set -euo pipefail

APP_DIR="${UPANEL_APP_DIR:-/opt/upanel}"
cd "${APP_DIR}"

echo "==> 1. System updates"
apt-get update -qq
apt-get upgrade -y -qq
if [[ -f /var/run/reboot-required ]]; then
  echo "    Reboot recommended after this script: reboot"
fi

echo "==> 2. Firewall (ufw)"
apt-get install -y -qq ufw
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw --force enable
ufw status

echo "==> 3. Restart application stack"
docker compose -f docker-compose.prod.yml --env-file .env.production up -d

echo "==> 4. Health check"
sleep 5
curl -sf http://127.0.0.1/api/health/ && echo ""

echo "==> 5. Create Django admin user (interactive)"
docker compose -f docker-compose.prod.yml exec web python manage.py createsuperuser

echo ""
echo "Done. Admin panel: http://169.58.135.136/admin/"
echo "Next: run setup-https.sh after DNS for api.orion13.us is ready."
