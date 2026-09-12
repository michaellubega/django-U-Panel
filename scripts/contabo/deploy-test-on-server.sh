#!/usr/bin/env bash
# Deploy a feature branch into the Contabo test tree at /opt/test.
# Isolated from production (/opt/upanel) — separate compose project, volumes, port 8080.
#
# Run ON the Contabo server as root:
#   bash scripts/contabo/deploy-test-on-server.sh
#   BRANCH=michael/oversight-dashboards-qaat-81ad bash scripts/contabo/deploy-test-on-server.sh
#
# Or from your Mac (one line):
#   ssh -p 443 -i ~/.ssh/id_ed25519 root@169.58.135.136 'bash -s' < scripts/contabo/deploy-test-on-server.sh

set -euo pipefail

APP_DIR="${UPANEL_TEST_DIR:-/opt/test}"
BRANCH="${BRANCH:-michael/oversight-dashboards-qaat-81ad}"
REPO_URL="${UPANEL_REPO_URL:-https://github.com/michaellubega/django-U-Panel.git}"
COMPOSE_PROJECT="${UPANEL_TEST_COMPOSE_PROJECT:-upanel-test}"
PROD_DIR="${UPANEL_APP_DIR:-/opt/upanel}"
HTTP_PORT="${TEST_HTTP_PORT:-8080}"

COMPOSE=(docker compose -p "${COMPOSE_PROJECT}" -f docker-compose.test.yml --env-file .env.test)

echo "==> Test deploy"
echo "    dir:    ${APP_DIR}"
echo "    branch: ${BRANCH}"
echo "    port:   ${HTTP_PORT}"
echo "    project:${COMPOSE_PROJECT}"

mkdir -p "${APP_DIR}"
cd "${APP_DIR}"

if [[ ! -d .git ]]; then
  echo "==> Cloning ${REPO_URL} into ${APP_DIR}"
  # Empty dir or leftover files — clone into temp then move if needed.
  if [[ -z "$(ls -A "${APP_DIR}" 2>/dev/null || true)" ]]; then
    git clone "${REPO_URL}" "${APP_DIR}"
  else
    TMP="$(mktemp -d)"
    git clone "${REPO_URL}" "${TMP}/repo"
    shopt -s dotglob
    mv "${TMP}/repo"/* "${APP_DIR}/"
    rmdir "${TMP}/repo" "${TMP}"
  fi
fi

cd "${APP_DIR}"

echo "==> Fetch + hard-reset to origin/${BRANCH}"
git remote set-url origin "${REPO_URL}" 2>/dev/null || true
git fetch origin "${BRANCH}"
git checkout -B "${BRANCH}" "origin/${BRANCH}"
git reset --hard "origin/${BRANCH}"
git clean -fd -e .env.test -e .env.production -e website/app
echo "    now at: $(git log -1 --oneline)"

if [[ ! -f .env.test ]]; then
  echo "==> Creating .env.test"
  if [[ -f "${PROD_DIR}/.env.production" ]]; then
    echo "    Seeded from ${PROD_DIR}/.env.production (edit secrets if you want isolation)"
    cp "${PROD_DIR}/.env.production" .env.test
    # Point public URLs at the test port and use a separate DB name in DATABASE_URL.
    python3 - <<'PY'
from pathlib import Path
p = Path(".env.test")
text = p.read_text(encoding="utf-8")
replacements = {
    "DJANGO_DEBUG=False": "DJANGO_DEBUG=True",
    "PUBLIC_API_URL=https://kiu.orion13.us": "PUBLIC_API_URL=http://169.58.135.136:8080",
    "PUBLIC_API_URL=http://169.58.135.136": "PUBLIC_API_URL=http://169.58.135.136:8080",
    "APP_RETURN_URL=https://kiu.orion13.us/app/": "APP_RETURN_URL=http://169.58.135.136:8080/app/",
    "APP_RETURN_URL=http://169.58.135.136/app/": "APP_RETURN_URL=http://169.58.135.136:8080/app/",
}
for a, b in replacements.items():
    text = text.replace(a, b)
if "TEST_HTTP_PORT=" not in text:
    text += "\nTEST_HTTP_PORT=8080\n"
if "upanel_test" not in text and "DATABASE_URL=" in text:
    text = text.replace("@db:5432/upanel", "@db:5432/upanel_test")
p.write_text(text, encoding="utf-8")
print("    adjusted PUBLIC_API_URL / APP_RETURN_URL / DATABASE_URL for :8080")
PY
  elif [[ -f .env.test.example ]]; then
    cp .env.test.example .env.test
    echo "    Copied .env.test.example — FILL POSTGRES_PASSWORD and DJANGO_SECRET_KEY before relying on this stack."
  else
    echo "ERROR: No .env.test and no template. Create ${APP_DIR}/.env.test first." >&2
    exit 1
  fi
fi

# Ensure TEST_HTTP_PORT is present for compose interpolation.
if ! grep -q '^TEST_HTTP_PORT=' .env.test; then
  echo "TEST_HTTP_PORT=${HTTP_PORT}" >> .env.test
fi

if ! grep -qE '^POSTGRES_PASSWORD=.+' .env.test; then
  echo "ERROR: POSTGRES_PASSWORD missing in ${APP_DIR}/.env.test" >&2
  exit 1
fi

echo "==> Build Flutter web for this branch (API → :${HTTP_PORT})"
if command -v flutter >/dev/null 2>&1; then
  flutter pub get
  BUILD_NUM="$(grep -E '^version:' pubspec.yaml | sed -E 's/.*\+([0-9]+).*/\1/')"
  VERSION_LABEL="$(grep -E '^version:' pubspec.yaml | sed -E 's/version: ([0-9.]+).*/\1/')"
  API_BASE="$(grep -E '^PUBLIC_API_URL=' .env.test | head -1 | cut -d= -f2- | tr -d '\r')"
  API_BASE="${API_BASE:-http://169.58.135.136:${HTTP_PORT}}"
  flutter build web --release \
    --dart-define=UPANEL_API_BASE_URL="${API_BASE}" \
    --dart-define=APP_BUILD_NUMBER="${BUILD_NUM}" \
    --dart-define=APP_VERSION_LABEL="${VERSION_LABEL}" \
    --base-href=/app/
  if [[ -f scripts/finalize-web-build.sh ]]; then
    bash scripts/finalize-web-build.sh
  fi
  rm -rf website/app
  mkdir -p website/app
  cp -a build/web/. website/app/
else
  echo "WARN: flutter not installed on server — using committed website/app (may be incomplete)." >&2
fi

if [[ ! -f website/app/index.html ]]; then
  echo "ERROR: website/app/index.html missing after web build." >&2
  exit 1
fi

echo "==> Rebuild + start test stack (project ${COMPOSE_PROJECT})"
"${COMPOSE[@]}" build --no-cache web nginx
"${COMPOSE[@]}" up -d --build
"${COMPOSE[@]}" exec -T web python manage.py migrate --noinput

echo "==> Health checks"
sleep 5
curl -sf "http://127.0.0.1:${HTTP_PORT}/api/health/" && echo " API OK"
APP_STATUS=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${HTTP_PORT}/app/")
echo " /app/ HTTP ${APP_STATUS}"
if [[ "${APP_STATUS}" != "200" ]]; then
  echo "WARN: /app/ returned ${APP_STATUS}. Check: ${COMPOSE[*]} logs nginx" >&2
fi

echo ""
echo "Test deploy OK."
echo "  Branch:  $(git log -1 --oneline)"
echo "  Web:     http://169.58.135.136:${HTTP_PORT}/app/"
echo "  API:     http://169.58.135.136:${HTTP_PORT}/api/health/"
echo "  Admin:   http://169.58.135.136:${HTTP_PORT}/admin/"
echo ""
echo "Production (/opt/upanel on :80) was not modified."
