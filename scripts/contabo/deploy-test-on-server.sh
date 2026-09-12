#!/usr/bin/env bash
# Deploy a feature branch into the Contabo test tree at /opt/test.
# Isolated from production (/opt/upanel) — separate compose project, volumes, host port.
# Public hostname: https://test.orion13.us
#
# Hostname path (preferred): prod nginx on :80 proxies Host: test.orion13.us →
# Docker DNS alias upanel-test-nginx:80 on shared external network upanel-edge.
# That hop does NOT use host.docker.internal or TEST_HTTP_PORT.
#
# Host port (TEST_HTTP_PORT): shell env if set → else existing .env.test → else 8080.
# Used only for direct IP access (curl http://127.0.0.1:PORT / http://SERVER_IP:PORT).
# Prefer 8085 when :8080 is already taken on the VPS:
#   TEST_HTTP_PORT=8085 bash scripts/contabo/deploy-test-on-server.sh
# Or set TEST_HTTP_PORT=8085 in /opt/test/.env.test (persists across deploys).
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
PUBLIC_HOST="${UPANEL_TEST_PUBLIC_HOST:-test.orion13.us}"
PUBLIC_URL="https://${PUBLIC_HOST}"
EDGE_NETWORK="${UPANEL_EDGE_NETWORK:-upanel-edge}"
TEST_NGINX_ALIAS="${UPANEL_TEST_NGINX_ALIAS:-upanel-test-nginx}"
# Resolved after .env.test exists (shell → .env.test → 8080). Placeholder for early logs.
HTTP_PORT="(resolving…)"

COMPOSE=(docker compose -p "${COMPOSE_PROJECT}" -f docker-compose.test.yml --env-file .env.test)

echo "==> Test deploy"
echo "    dir:    ${APP_DIR}"
echo "    branch: ${BRANCH}"
echo "    public: ${PUBLIC_URL}"
echo "    project:${COMPOSE_PROJECT}"
echo "    edge:   ${EDGE_NETWORK} → ${TEST_NGINX_ALIAS}:80"

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

# Resolve host bind port: explicit shell TEST_HTTP_PORT wins; otherwise keep
# whatever is already in .env.test; only default to 8080 when neither is set.
# Never overwrite an existing .env.test TEST_HTTP_PORT with a blind shell default.
# This port is for direct IP access only — hostname uses Docker network DNS.
if [[ -n "${TEST_HTTP_PORT:-}" ]]; then
  HTTP_PORT="${TEST_HTTP_PORT}"
  echo "==> HTTP port: ${HTTP_PORT} (from shell TEST_HTTP_PORT; direct IP only)"
else
  ENV_PORT="$(grep -E '^TEST_HTTP_PORT=' .env.test 2>/dev/null | head -1 | cut -d= -f2- | tr -d '\r' | tr -d '\"' | tr -d "'" | tr -d ' ' || true)"
  if [[ -n "${ENV_PORT}" ]]; then
    HTTP_PORT="${ENV_PORT}"
    echo "==> HTTP port: ${HTTP_PORT} (from .env.test TEST_HTTP_PORT — preserved; direct IP only)"
  else
    HTTP_PORT=8080
    echo "==> HTTP port: ${HTTP_PORT} (default; set TEST_HTTP_PORT=8085 if :8080 is taken)"
  fi
fi

echo "==> Normalize .env.test for ${PUBLIC_URL} (TEST_HTTP_PORT=${HTTP_PORT})"
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

# Always pin the test stack to its own Postgres service (compose project
# upanel-test, service db, database upanel_test). Prod-seeded .env.test often
# still has DATABASE_URL=...@db:5432/upanel, a remote host, sqlite, or a
# password embedded that drifted from POSTGRES_PASSWORD.
# Compose interpolates ${POSTGRES_PASSWORD} into web/worker/beat DATABASE_URL
# and into the db container — keep the template form so they stay in sync.
text = set_key(
    text,
    "DATABASE_URL",
    "postgres://upanel:${POSTGRES_PASSWORD}@db:5432/upanel_test",
)
# Never fall back to SQLite inside the test containers.
text = re.sub(r"(?m)^DJANGO_USE_SQLITE=.*\n?", "", text)

p.write_text(text, encoding="utf-8")
print(f"    PUBLIC_API_URL={public_url}")
print("    DATABASE_URL=postgres://upanel:${POSTGRES_PASSWORD}@db:5432/upanel_test")
PY

if ! grep -qE '^POSTGRES_PASSWORD=.+' .env.test; then
  echo "ERROR: POSTGRES_PASSWORD missing in ${APP_DIR}/.env.test" >&2
  exit 1
fi

if grep -qE '^POSTGRES_PASSWORD=[[:space:]]*$' .env.test; then
  echo "ERROR: POSTGRES_PASSWORD is empty in ${APP_DIR}/.env.test" >&2
  exit 1
fi
if grep -qE '^POSTGRES_PASSWORD=(generate-a-strong-test-password|generate-a-strong-password)[[:space:]]*$' .env.test; then
  echo "WARN: POSTGRES_PASSWORD still looks like the example placeholder — fine if the volume was init'd with it." >&2
fi

echo "==> Ensure shared Docker network ${EDGE_NETWORK}"
docker network create "${EDGE_NETWORK}" 2>/dev/null || true
docker network inspect "${EDGE_NETWORK}" >/dev/null

echo "==> Build Flutter web for this branch (API → ${PUBLIC_URL}, same-origin)"
if command -v flutter >/dev/null 2>&1; then
  flutter pub get
  BUILD_NUM="$(grep -E '^version:' pubspec.yaml | sed -E 's/.*\+([0-9]+).*/\1/')"
  VERSION_LABEL="$(grep -E '^version:' pubspec.yaml | sed -E 's/version: ([0-9.]+).*/\1/')"
  # Prefer PUBLIC_URL (https://test.orion13.us). Never bake http://IP — HTTPS pages
  # would mixed-content-block and AppConnectivity shows "No internet connection".
  # web/index.html also sets window.upanelApiBaseUrl to same-origin at runtime.
  API_BASE="$(grep -E '^PUBLIC_API_URL=' .env.test | head -1 | cut -d= -f2- | tr -d '\r' | tr -d '\"' | tr -d "'")"
  API_BASE="${API_BASE:-${PUBLIC_URL}}"
  case "${API_BASE}" in
    http://169.58.135.136*|http://127.0.0.1*|http://localhost*)
      echo "WARN: PUBLIC_API_URL=${API_BASE} is cleartext — forcing ${PUBLIC_URL} for web build" >&2
      API_BASE="${PUBLIC_URL}"
      ;;
  esac
  if [[ -z "${API_BASE}" || "${API_BASE}" == "http://"* && "${API_BASE}" != *"orion13.us"* ]]; then
    API_BASE="${PUBLIC_URL}"
  fi
  echo "    dart-define UPANEL_API_BASE_URL=${API_BASE}"
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

# Runtime bootstrap must same-origin *.orion13.us (including test). Fail loud if stale.
if ! grep -q 'isOrionHost' website/app/index.html || \
   ! grep -q "host.endsWith('.orion13.us')" website/app/index.html; then
  echo "ERROR: website/app/index.html missing same-origin Orion API bootstrap." >&2
  echo "  Expected isOrionHost() / endsWith('.orion13.us') so https://test.orion13.us" >&2
  echo "  does not call http://169.58.135.136 (mixed content → offline banner)." >&2
  exit 1
fi
if grep -q "return 'http://169.58.135.136'" website/app/index.html; then
  echo "ERROR: website/app/index.html still hardcodes http://169.58.135.136 as API default." >&2
  exit 1
fi
echo "    index.html API bootstrap: same-origin for *.orion13.us OK"

echo "==> Rebuild + start test stack (project ${COMPOSE_PROJECT})"
"${COMPOSE[@]}" build --no-cache web nginx
"${COMPOSE[@]}" up -d --build --force-recreate nginx
"${COMPOSE[@]}" up -d --build

echo "==> Verify Django ↔ Postgres (upanel_test)"
db_ok=0
for _try in 1 2 3 4 5 6 7 8 9 10; do
  if "${COMPOSE[@]}" exec -T web python manage.py check --database default >/dev/null 2>&1; then
    db_ok=1
    break
  fi
  sleep 3
done
if [[ "${db_ok}" -ne 1 ]]; then
  echo "ERROR: web cannot authenticate to Postgres (upanel_test)." >&2
  echo "  Common cause: POSTGRES_PASSWORD in .env.test changed after the volume was first created." >&2
  echo "  Postgres keeps the password from the initial volume init." >&2
  echo "  Fix A — align .env.test POSTGRES_PASSWORD with the original volume password, then:" >&2
  echo "    ${COMPOSE[*]} up -d --force-recreate web worker beat" >&2
  echo "  Fix B — wipe TEST volumes only (does NOT touch production /opt/upanel data):" >&2
  echo "    cd ${APP_DIR}" >&2
  echo "    ${COMPOSE[*]} down -v" >&2
  echo "    ${COMPOSE[*]} up -d --build" >&2
  echo "    ${COMPOSE[*]} exec -T web python manage.py migrate --noinput" >&2
  echo "  Logs: ${COMPOSE[*]} logs --tail=100 db web" >&2
  "${COMPOSE[@]}" ps || true
  "${COMPOSE[@]}" logs --tail=40 db web || true
  exit 1
fi

"${COMPOSE[@]}" exec -T web python manage.py migrate --noinput

echo "==> Wire production nginx to proxy ${PUBLIC_HOST} → ${TEST_NGINX_ALIAS}:80 (${EDGE_NETWORK})"
if [[ -d "${PROD_DIR}" && -f "${PROD_DIR}/docker-compose.prod.yml" ]]; then
  mkdir -p "${PROD_DIR}/config/nginx"
  NGINX_SRC="${APP_DIR}/config/nginx/upanel-docker.conf"
  NGINX_DST="${PROD_DIR}/config/nginx/upanel-docker.conf"
  cp -a "${NGINX_SRC}" "${NGINX_DST}"
  if ! grep -q "proxy_pass http://${TEST_NGINX_ALIAS}:80;" "${NGINX_DST}"; then
    echo "ERROR: ${NGINX_DST} missing proxy_pass http://${TEST_NGINX_ALIAS}:80;" >&2
    exit 1
  fi
  echo "    nginx proxy_pass → ${TEST_NGINX_ALIAS}:80 (Docker DNS on ${EDGE_NETWORK})"

  # Ensure /opt/upanel's compose attaches nginx to upanel-edge even if prod
  # checkout is still on an older commit without the network block.
  EDGE_NETWORK="${EDGE_NETWORK}" PROD_COMPOSE="${PROD_DIR}/docker-compose.prod.yml" python3 - <<'PY'
import os
import re
from pathlib import Path

edge = os.environ["EDGE_NETWORK"]
p = Path(os.environ["PROD_COMPOSE"])
text = p.read_text(encoding="utf-8")
changed = False

# Match only the nginx service body (indented lines / blanks). Do NOT swallow
# following top-level keys like volumes: / networks: when nginx is last.
# Avoid DOTALL — otherwise ".*" crosses newlines into volumes:.
nginx_m = re.search(r"(?m)^  nginx:\n(?:    [^\n]*\n|\n)*", text)
if not nginx_m:
    raise SystemExit("ERROR: nginx service not found in production docker-compose.prod.yml")
block = nginx_m.group(0)
if edge not in block:
    # Insert networks under nginx before depends_on (or at end of service).
    if re.search(r"(?m)^    networks:\s*$", block):
        block2 = re.sub(
            r"(?m)^    networks:\s*\n",
            f"    networks:\n      - {edge}\n",
            block,
            count=1,
        )
        if block2 == block:
            block2 = block.rstrip("\n") + f"\n    networks:\n      - default\n      - {edge}\n"
    elif "    depends_on:\n" in block:
        block2 = block.replace(
            "    depends_on:\n",
            f"    networks:\n      - default\n      - {edge}\n    depends_on:\n",
            1,
        )
    else:
        block2 = block.rstrip("\n") + f"\n    networks:\n      - default\n      - {edge}\n"
    text = text[: nginx_m.start()] + block2 + text[nginx_m.end() :]
    changed = True
    print(f"    attached prod nginx to {edge}")

# Ensure top-level external network declaration.
if f"name: {edge}" not in text and re.search(rf"(?m)^  {re.escape(edge)}:\s*$", text) is None:
    if not re.search(r"(?m)^networks:\s*$", text):
        if text and not text.endswith("\n"):
            text += "\n"
        text += "\nnetworks:\n"
    text += f"  {edge}:\n    external: true\n    name: {edge}\n"
    changed = True
    print(f"    declared external network {edge} in production compose")

if changed:
    p.write_text(text, encoding="utf-8")
else:
    print(f"    production compose already joins {edge}")
PY

  (
    cd "${PROD_DIR}"
    # Force recreate so nginx actually joins upanel-edge (config-only up can miss it).
    docker compose -f docker-compose.prod.yml --env-file .env.production up -d --build --force-recreate nginx
  )
  echo "    production nginx rebuilt (kiu unchanged; ${PUBLIC_HOST} → ${TEST_NGINX_ALIAS}:80)"
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

# From inside prod nginx: Docker DNS to test nginx on upanel-edge.
PROD_NGINX_CID="$(
  cd "${PROD_DIR}" 2>/dev/null \
    && docker compose -f docker-compose.prod.yml --env-file .env.production ps -q nginx 2>/dev/null \
    || true
)"
if [[ -n "${PROD_NGINX_CID}" ]]; then
  if docker exec "${PROD_NGINX_CID}" wget -q -O - "http://${TEST_NGINX_ALIAS}/api/health/" >/dev/null 2>&1; then
    echo " Prod nginx → ${TEST_NGINX_ALIAS}/api/health/ OK (Docker DNS)"
  else
    echo "WARN: prod nginx cannot reach ${TEST_NGINX_ALIAS} on ${EDGE_NETWORK}." >&2
    echo "      Check: docker network inspect ${EDGE_NETWORK}" >&2
  fi
fi

echo ""
echo "Test deploy OK."
echo "  Branch:  $(git log -1 --oneline)"
echo "  Public:  ${PUBLIC_URL}/app/"
echo "  API:     ${PUBLIC_URL}/api/health/"
echo "  Admin:   ${PUBLIC_URL}/admin/"
echo "  Direct:  http://169.58.135.136:${HTTP_PORT}/app/"
echo "  Edge:    ${EDGE_NETWORK} → ${TEST_NGINX_ALIAS}:80"
echo ""
echo "DNS once (Cloudflare): A  test  →  169.58.135.136  (Proxied, SSL Flexible)."
echo "Production app at https://kiu.orion13.us was not replaced — only nginx gained the test hostname proxy."
