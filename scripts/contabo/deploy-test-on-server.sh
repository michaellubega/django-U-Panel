#!/usr/bin/env bash
# Deploy a feature branch into the Contabo test tree at /opt/test.
# Isolated from production (/opt/upanel) — separate compose project, volumes, port 8080.
# Public hostname: https://test.orion13.us (prod nginx on :80 proxies Host → :8080).
#
# Run ON the Contabo server as root:
#   bash scripts/contabo/deploy-test-on-server.sh
#   BRANCH=michael/oversight-dashboards-qaat-81ad bash scripts/contabo/deploy-test-on-server.sh
#
# Or from your Mac (one line):
#   ssh -p 443 -i ~/.ssh/id_ed25519 root@169.58.135.136 'bash -s' < scripts/contabo/deploy-test-on-server.sh
#
# Cloudflare DNS (once): A record test → 169.58.135.136, Proxied, SSL Flexible (same as kiu).

set -euo pipefail

APP_DIR="${UPANEL_TEST_DIR:-/opt/test}"
BRANCH="${BRANCH:-michael/oversight-dashboards-qaat-81ad}"
REPO_URL="${UPANEL_REPO_URL:-https://github.com/michaellubega/django-U-Panel.git}"
COMPOSE_PROJECT="${UPANEL_TEST_COMPOSE_PROJECT:-upanel-test}"
PROD_DIR="${UPANEL_APP_DIR:-/opt/upanel}"
HTTP_PORT="${TEST_HTTP_PORT:-8080}"
PUBLIC_HOST="${UPANEL_TEST_PUBLIC_HOST:-test.orion13.us}"
PUBLIC_URL="https://${PUBLIC_HOST}"

COMPOSE=(docker compose -p "${COMPOSE_PROJECT}" -f docker-compose.test.yml --env-file .env.test)

echo "==> Test deploy"
echo "    dir:    ${APP_DIR}"
echo "    branch: ${BRANCH}"
echo "    port:   ${HTTP_PORT}"
echo "    public: ${PUBLIC_URL}"
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
  elif [[ -f .env.test.example ]]; then
    cp .env.test.example .env.test
    echo "    Copied .env.test.example — FILL POSTGRES_PASSWORD and DJANGO_SECRET_KEY before relying on this stack."
  else
    echo "ERROR: No .env.test and no template. Create ${APP_DIR}/.env.test first." >&2
    exit 1
  fi
fi

echo "==> Normalize .env.test for ${PUBLIC_URL}"
PUBLIC_HOST="${PUBLIC_HOST}" PUBLIC_URL="${PUBLIC_URL}" HTTP_PORT="${HTTP_PORT}" python3 - <<'PY'
import os
import re
from pathlib import Path

public_host = os.environ["PUBLIC_HOST"]
public_url = os.environ["PUBLIC_URL"]
http_port = os.environ["HTTP_PORT"]
p = Path(".env.test")
text = p.read_text(encoding="utf-8")

def set_key(content: str, key: str, value: str) -> str:
    line = f"{key}={value}"
    pattern = re.compile(rf"(?m)^{re.escape(key)}=.*$")
    if pattern.search(content):
        return pattern.sub(line, content)
    if content and not content.endswith("\n"):
        content += "\n"
    return content + line + "\n"

text = text.replace("DJANGO_DEBUG=False", "DJANGO_DEBUG=True")
text = set_key(text, "PUBLIC_API_URL", public_url)
text = set_key(text, "APP_RETURN_URL", f"{public_url}/app/")
text = set_key(text, "TEST_HTTP_PORT", http_port)

# Hosts / CORS / CSRF — keep existing values but ensure test host is present.
def ensure_csv(content: str, key: str, required: list[str]) -> str:
    m = re.search(rf"(?m)^{re.escape(key)}=(.*)$", content)
    if not m:
        return set_key(content, key, ",".join(required))
    parts = [x.strip() for x in m.group(1).split(",") if x.strip()]
    for item in required:
        if item not in parts:
            parts.append(item)
    return set_key(content, key, ",".join(parts))

text = ensure_csv(
    text,
    "DJANGO_ALLOWED_HOSTS",
    [public_host, "169.58.135.136", "localhost", "127.0.0.1"],
)
text = ensure_csv(
    text,
    "CORS_ALLOWED_ORIGINS",
    [
        public_url,
        f"http://169.58.135.136:{http_port}",
        f"http://localhost:{http_port}",
        "http://localhost",
    ],
)
text = ensure_csv(
    text,
    "CSRF_TRUSTED_ORIGINS",
    [
        public_url,
        f"http://169.58.135.136:{http_port}",
        f"http://localhost:{http_port}",
    ],
)

if "upanel_test" not in text and "DATABASE_URL=" in text:
    text = text.replace("@db:5432/upanel", "@db:5432/upanel_test")

p.write_text(text, encoding="utf-8")
print(f"    PUBLIC_API_URL={public_url}")
PY

if ! grep -qE '^POSTGRES_PASSWORD=.+' .env.test; then
  echo "ERROR: POSTGRES_PASSWORD missing in ${APP_DIR}/.env.test" >&2
  exit 1
fi

echo "==> Build Flutter web for this branch (API → ${PUBLIC_URL})"
if command -v flutter >/dev/null 2>&1; then
  flutter pub get
  BUILD_NUM="$(grep -E '^version:' pubspec.yaml | sed -E 's/.*\+([0-9]+).*/\1/')"
  VERSION_LABEL="$(grep -E '^version:' pubspec.yaml | sed -E 's/version: ([0-9.]+).*/\1/')"
  API_BASE="$(grep -E '^PUBLIC_API_URL=' .env.test | head -1 | cut -d= -f2- | tr -d '\r')"
  API_BASE="${API_BASE:-${PUBLIC_URL}}"
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

echo "==> Wire production nginx to proxy ${PUBLIC_HOST} → 127.0.0.1:${HTTP_PORT}"
if [[ -d "${PROD_DIR}" && -f "${PROD_DIR}/docker-compose.prod.yml" ]]; then
  mkdir -p "${PROD_DIR}/config/nginx"
  cp -a "${APP_DIR}/config/nginx/upanel-docker.conf" "${PROD_DIR}/config/nginx/upanel-docker.conf"
  # Ensure host.docker.internal is available for the proxy hop.
  if ! grep -q 'host.docker.internal:host-gateway' "${PROD_DIR}/docker-compose.prod.yml"; then
    python3 - <<PY
from pathlib import Path
p = Path("${PROD_DIR}/docker-compose.prod.yml")
text = p.read_text(encoding="utf-8")
needle = "  nginx:\n"
if "host.docker.internal:host-gateway" not in text and needle in text:
    # Insert extra_hosts under nginx service ports block if missing.
    import re
    m = re.search(r"(?ms)^  nginx:\n(?:.*?\n)*?(?=^  [a-z]|\Z)", text)
    if m:
        block = m.group(0)
        if "extra_hosts:" not in block:
            block2 = block.replace(
                '    ports:\n      - "80:80"\n',
                '    ports:\n      - "80:80"\n    extra_hosts:\n      - "host.docker.internal:host-gateway"\n',
                1,
            )
            text = text[: m.start()] + block2 + text[m.end() :]
            p.write_text(text, encoding="utf-8")
            print("    added extra_hosts to production docker-compose.prod.yml")
PY
  fi
  (
    cd "${PROD_DIR}"
    docker compose -f docker-compose.prod.yml --env-file .env.production up -d --build nginx
  )
  echo "    production nginx rebuilt (kiu unchanged; ${PUBLIC_HOST} → :${HTTP_PORT})"
else
  echo "WARN: ${PROD_DIR} missing — skipped hostname proxy. Direct IP :${HTTP_PORT} still works." >&2
fi

echo "==> Health checks"
sleep 5
curl -sf "http://127.0.0.1:${HTTP_PORT}/api/health/" && echo " API OK (:${HTTP_PORT})"
APP_STATUS=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${HTTP_PORT}/app/")
echo " /app/ HTTP ${APP_STATUS} on :${HTTP_PORT}"
if [[ "${APP_STATUS}" != "200" ]]; then
  echo "WARN: /app/ returned ${APP_STATUS}. Check: ${COMPOSE[*]} logs nginx" >&2
fi

HOST_STATUS=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: ${PUBLIC_HOST}" "http://127.0.0.1/api/health/" || true)
echo " Host ${PUBLIC_HOST} via :80 → HTTP ${HOST_STATUS:-000}"

echo ""
echo "Test deploy OK."
echo "  Branch:  $(git log -1 --oneline)"
echo "  Public:  ${PUBLIC_URL}/app/"
echo "  API:     ${PUBLIC_URL}/api/health/"
echo "  Admin:   ${PUBLIC_URL}/admin/"
echo "  Direct:  http://169.58.135.136:${HTTP_PORT}/app/"
echo ""
echo "DNS once (Cloudflare): A  test  →  169.58.135.136  (Proxied, SSL Flexible)."
echo "Production app at https://kiu.orion13.us was not replaced — only nginx gained the test hostname proxy."
