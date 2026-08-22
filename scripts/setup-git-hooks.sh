#!/bin/sh
# Enable repo git hooks (.githooks) for Cursor co-author stripping.
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
chmod +x .githooks/prepare-commit-msg
git config core.hooksPath .githooks
echo "Git hooks enabled (core.hooksPath=.githooks)"
