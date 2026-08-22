#!/bin/sh
# Ensure commits use the repo owner identity (never Cursor Agent).
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
git config user.name "Michael"
git config user.email "michaeldieve@gmail.com"
if [ "${UPANEL_ENABLE_GIT_HOOKS:-1}" != "0" ] && [ -f "$ROOT/scripts/setup-git-hooks.sh" ]; then
  "$ROOT/scripts/setup-git-hooks.sh" >/dev/null
fi
