#!/usr/bin/env bash
# Fix common .env.production mistakes on the Contabo VPS (PUBLIC_API_URL typo, CORS, hosts).
# Usage on server: bash scripts/contabo/fix-production-env.sh
set -euo pipefail

APP_DIR="${UPANEL_APP_DIR:-/opt/upanel}"
ENV_FILE="${APP_DIR}/.env.production"
EXAMPLE="${APP_DIR}/.env.production.example"

if [[ ! -d "$APP_DIR" ]]; then
  echo "Missing $APP_DIR — run from the server after git pull." >&2
  exit 1
fi

cd "$APP_DIR"

if [[ ! -f "$ENV_FILE" ]]; then
  if [[ -f "$EXAMPLE" ]]; then
    cp "$EXAMPLE" "$ENV_FILE"
    echo "Created $ENV_FILE from example — edit secrets, then re-run."
    exit 0
  fi
  echo "No $ENV_FILE found." >&2
  exit 1
fi

backup="${ENV_FILE}.bak.$(date +%Y%m%d%H%M%S)"
cp "$ENV_FILE" "$backup"
echo "Backed up to $backup"

python3 - "$ENV_FILE" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines()

def upsert(key: str, value: str, out: list[str]) -> None:
    pat = re.compile(rf"^{re.escape(key)}=")
    replaced = False
    for i, line in enumerate(out):
        if pat.match(line):
            out[i] = f"{key}={value}"
            replaced = True
            break
    if not replaced:
        out.append(f"{key}={value}")

out: list[str] = []
for line in lines:
    # Drop broken duplicate PUBLIC_API_URL lines; we upsert a clean one below.
    if line.startswith("PUBLIC_API_URL=PUBLIC_API_URL="):
        continue
    if line.startswith("PUBLIC_API_URL=") and "PUBLIC_API_URL=" in line[ len("PUBLIC_API_URL="):]:
        continue
    out.append(line)

upsert("DJANGO_DEBUG", "False", out)
upsert(
    "DJANGO_ALLOWED_HOSTS",
    "169.58.135.136,api.orion13.us,kiu.orion13.us,localhost,127.0.0.1",
    out,
)
upsert(
    "CORS_ALLOWED_ORIGINS",
    "https://kiu.orion13.us,https://api.orion13.us,http://169.58.135.136,http://localhost",
    out,
)
upsert("CSRF_TRUSTED_ORIGINS", "https://kiu.orion13.us,https://api.orion13.us", out)
upsert("PUBLIC_API_URL", "https://kiu.orion13.us", out)
upsert("APP_RETURN_URL", "https://kiu.orion13.us/app/", out)
upsert("ONESIGNAL_APP_ID", "882dcbec-c505-4c12-95c5-78da7e8ef25c", out)

path.write_text("\n".join(out).rstrip() + "\n", encoding="utf-8")
print("Updated", path)
PY

echo ""
echo "==> Restarting API containers"
docker compose -f docker-compose.prod.yml --env-file .env.production restart web worker beat

echo ""
echo "==> Health check (local)"
curl -sf http://127.0.0.1/api/health/ || curl -sf http://169.58.135.136/api/health/ || true
echo ""
echo "==> OneSignal push status"
curl -sf http://127.0.0.1/api/client-config/ || true
echo ""
if ! grep -q '^ONESIGNAL_REST_API_KEY=.\+' "$ENV_FILE" 2>/dev/null; then
  echo "WARN: ONESIGNAL_REST_API_KEY is empty — server cannot send push notifications."
  echo "      Set it in OneSignal Dashboard → Settings → Keys & IDs → App API Key"
  echo "      Then run: ONESIGNAL_REST_API_KEY='os_v2_app_...' bash scripts/contabo/configure-onesignal.sh"
fi

echo ""
echo "Done. After Cloudflare DNS (kiu → 169.58.135.136 proxied), verify:"
echo "  curl -sf https://kiu.orion13.us/api/health/"
