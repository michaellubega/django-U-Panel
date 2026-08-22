#!/usr/bin/env python3
"""Remove Cursor co-author trailers from git commit messages (stdin -> stdout)."""
import sys

CURSOR_MARKERS = (
    "cursoragent@cursor.com",
    "co-authored-by: cursor",
)


def should_drop(line: str) -> bool:
    normalized = line.strip().lower()
    if not normalized.startswith("co-authored-by:"):
        return False
    return any(marker in normalized for marker in CURSOR_MARKERS)


for line in sys.stdin:
    if should_drop(line):
        continue
    sys.stdout.write(line)
