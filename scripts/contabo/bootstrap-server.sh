#!/usr/bin/env bash
# One-time fix when /opt/upanel exists but is NOT a git clone (no scripts/, no git pull).
# Preserves .env.production and Docker volumes, then clones the repo and deploys.
#
# Run ON the Contabo server as root:
#   curl -fsSL https://raw.githubusercontent.com/michaellubega/django-U-Panel/main/scripts/contabo/bootstrap-server.sh | bash

set -euo pipefail

APP_DIR="${UPANEL_APP_DIR:-/opt/upanel}"
REPO="${UPANEL_REPO:-https://github.com/michaellubega/django-U-Panel.git}"
BRANCH="${UPANEL_BRANCH:-main}"
BACKUP_DIR="/root/upanel-bootstrap-backup-$(date +%Y%m%d-%H%M%S)"

echo "==> U-Panel server bootstrap"
echo "    App dir: ${APP_DIR}"
echo "    Repo:    ${REPO}"

mkdir -p "${BACKUP_DIR}"

if [[ -d "${APP_DIR}" ]]; then
  echo "==> Backing up existing ${APP_DIR} to ${BACKUP_DIR}/upanel-old"
  for f in .env.production .env .env.production.local docker-compose.prod.yml; do
    if [[ -f "${APP_DIR}/${f}" ]]; then
      cp -a "${APP_DIR}/${f}" "${BACKUP_DIR}/"
      echo "    saved ${f}"
    fi
  done
  if docker compose -f "${APP_DIR}/docker-compose.prod.yml" ps -q 2>/dev/null | grep -q .; then
    echo "==> Stopping old Docker stack (volumes are kept)"
    (cd "${APP_DIR}" && docker compose -f docker-compose.prod.yml --env-file .env.production down 2>/dev/null) \
      || (cd "${APP_DIR}" && docker compose -f docker-compose.prod.yml down 2>/dev/null) \
      || true
  fi
  mv "${APP_DIR}" "${BACKUP_DIR}/upanel-old"
fi

echo "==> Cloning repository"
git clone --branch "${BRANCH}" --depth 1 "${REPO}" "${APP_DIR}"
cd "${APP_DIR}"

if [[ -f "${BACKUP_DIR}/.env.production" ]]; then
  cp -a "${BACKUP_DIR}/.env.production" "${APP_DIR}/.env.production"
  echo "==> Restored .env.production from backup"
elif [[ -f "${BACKUP_DIR}/.env" ]]; then
  cp -a "${BACKUP_DIR}/.env" "${APP_DIR}/.env.production"
  echo "==> Restored .env as .env.production"
else
  echo "==> No .env.production backup found — creating from example"
  cp .env.production.example .env.production
  echo "    EDIT REQUIRED: nano ${APP_DIR}/.env.production"
  echo "    Set DJANGO_SECRET_KEY, POSTGRES_PASSWORD, MAILJET keys, then re-run deploy."
fi

ln -sf .env.production .env

echo "==> Deploy web app + API stack"
bash scripts/contabo/deploy-web-on-server.sh

echo ""
echo "Bootstrap complete."
echo "  Backup of old files: ${BACKUP_DIR}"
echo "  Web app:  http://169.58.135.136/app/"
echo "  API:      http://169.58.135.136/api/health/"
echo "  HTTPS:    bash scripts/contabo/setup-cloudflare-https.sh"
