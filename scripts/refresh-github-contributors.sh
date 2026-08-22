#!/bin/sh
# Flush GitHub's cached contributor sidebar (cursoragent can linger after history rewrite).
# Requires repo admin in a browser: Settings → General → Default branch → switch
# main → main-refresh → back to main. This script creates main-refresh if missing.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SHA="$(git rev-parse main)"
if git ls-remote --exit-code origin refs/heads/main-refresh >/dev/null 2>&1; then
  git push origin "$SHA:refs/heads/main-refresh" --force
else
  git push origin "$SHA:refs/heads/main-refresh"
fi
cat <<'EOF'

Created/updated remote branch `main-refresh` (same commit as main).

To flush GitHub's contributor cache (remove stale cursoragent):
  1. GitHub → repo Settings → General → Default branch
  2. Change default branch to `main-refresh`, save
  3. Change default branch back to `main`, save
  4. Optional: delete branch `main-refresh`

If cursoragent still appears after 24h, contact GitHub Support and ask them
to refresh the contributor graph for this repository.
EOF
