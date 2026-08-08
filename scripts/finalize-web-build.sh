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
  python3 - "$ASSETS" <<'PY'
import json, sys
from pathlib import Path

assets = Path(sys.argv[1])
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

# Ensure CanvasKit loads under <base href> (e.g. /app/canvaskit/), not site root.
if [[ -f "$WEB/flutter_bootstrap.js" ]]; then
  python3 - "$WEB/flutter_bootstrap.js" <<'PY'
import re, sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
if "canvasKitBaseUrl: '/canvaskit/'" in text or 'canvasKitBaseUrl: "/canvaskit/"' in text:
    text = re.sub(
        r"_flutter\.loader\.load\(\{\s*config:\s*\{\s*canvasKitBaseUrl:\s*['\"]/canvaskit/['\"],\s*\},\s*\}\);",
        """(function () {
  var baseEl = document.querySelector('base');
  var root = (baseEl && baseEl.getAttribute('href')) || '/';
  if (!root.endsWith('/')) root += '/';
  _flutter.loader.load({
    config: {
      canvasKitBaseUrl: root + 'canvaskit/',
    },
  });
})();""",
        text,
        count=1,
    )
    path.write_text(text, encoding="utf-8")
    print("Patched flutter_bootstrap.js canvasKitBaseUrl for subpath deploy")
PY
fi

echo "Web build verification passed."

# Disable Flutter PWA caching — stale service workers caused infinite reload / stuck splash.
cat > "$WEB/flutter_service_worker.js" <<'SWEOF'
'use strict';
// U-Panel: unregister any legacy Flutter service worker (no offline cache).
self.addEventListener('install', (event) => {
  self.skipWaiting();
});
self.addEventListener('activate', (event) => {
  event.waitUntil(
    (async () => {
      try {
        await self.registration.unregister();
      } catch (_) {}
    })(),
  );
});
SWEOF
echo "Wrote no-op flutter_service_worker.js"
