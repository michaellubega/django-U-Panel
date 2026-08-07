#!/usr/bin/env bash
# Post-process build/web before GitHub Pages deploy (bash port of finalize-web-build.ps1).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WEB="$ROOT/build/web"
ASSETS="$WEB/assets"

if [[ ! -f "$WEB/index.html" ]]; then
  echo "build/web not found. Run: flutter build web --release" >&2
  exit 1
fi

if [[ -d "$ASSETS" ]]; then
  python3 <<'PY'
import json, os
from pathlib import Path

assets = Path(os.environ["ASSETS"])
manifest = {}
for p in sorted(assets.rglob("*")):
    if not p.is_file():
        continue
    name = p.name
    if name.startswith("AssetManifest") or name in ("FontManifest.json", "NOTICES"):
        continue
    rel = p.relative_to(assets).as_posix()
    manifest[rel] = [rel]
out = assets / "AssetManifest.json"
out.write_text(json.dumps(manifest, separators=(",", ":")), encoding="utf-8")
print(f"Wrote legacy {out} ({len(manifest)} assets)")
PY
fi

CANVASKIT="$WEB/canvaskit"
if [[ -d "$CANVASKIT" ]]; then
  rm -f "$CANVASKIT"/skwasm* "$CANVASKIT"/wimp* 2>/dev/null || true
  rm -rf "$CANVASKIT/experimental_webparagraph" 2>/dev/null || true
  find "$CANVASKIT" -name '*.symbols' -delete 2>/dev/null || true
fi

for gate in android_web_gate.js upanel_brand.js; do
  [[ -f "$ROOT/web/$gate" ]] && cp "$ROOT/web/$gate" "$WEB/$gate"
done

echo "Web build verification passed."
