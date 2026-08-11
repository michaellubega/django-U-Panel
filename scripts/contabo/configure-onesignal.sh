#!/usr/bin/env bash
# Configure OneSignal push delivery on the Contabo VPS.
#
# Get your App API Key from OneSignal Dashboard → Settings → Keys & IDs.
# Usage on server:
#   ONESIGNAL_REST_API_KEY='os_v2_app_...' bash scripts/contabo/configure-onesignal.sh
#
# Optional:
#   ONESIGNAL_APP_ID='882dcbec-c505-4c12-95c5-78da7e8ef25c'

set -euo pipefail

APP_DIR="${UPANEL_APP_DIR:-/opt/upanel}"
ENV_FILE="${APP_DIR}/.env.production"
REST_KEY="${ONESIGNAL_REST_API_KEY:-}"
APP_ID="${ONESIGNAL_APP_ID:-882dcbec-c505-4c12-95c5-78da7e8ef25c}"

if [[ ! -d "$APP_DIR" ]]; then
  echo "Missing $APP_DIR — run on the server after git pull." >&2
  exit 1
fi

if [[ -z "$REST_KEY" ]]; then
  echo "ERROR: Set ONESIGNAL_REST_API_KEY (OneSignal App API Key)." >&2
  echo "Dashboard → Settings → Keys & IDs → Create App API Key" >&2
  exit 1
fi

cd "$APP_DIR"

if [[ ! -f "$ENV_FILE" ]]; then
  bash scripts/contabo/fix-production-env.sh
fi

backup="${ENV_FILE}.bak.$(date +%Y%m%d%H%M%S)"
cp "$ENV_FILE" "$backup"
echo "Backed up to $backup"

python3 - "$ENV_FILE" "$APP_ID" "$REST_KEY" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
app_id = sys.argv[2].strip()
rest_key = sys.argv[3].strip()
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

upsert("ONESIGNAL_APP_ID", app_id, lines)
upsert("ONESIGNAL_REST_API_KEY", rest_key, lines)
path.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
print("Updated OneSignal settings in", path)
PY

echo ""
echo "==> Recreating API containers (reload .env.production)"
bash scripts/contabo/restart-api-containers.sh

echo ""
echo "Expected: push_enabled=true and push_delivery_configured=true"
