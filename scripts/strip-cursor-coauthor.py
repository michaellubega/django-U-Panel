#!/usr/bin/env python3
"""Remove Cursor co-author trailers from git commit messages (stdin -> stdout)."""
import sys

SKIP = "Co-authored-by: Cursor <cursoragent@cursor.com>"

for line in sys.stdin:
    if line.rstrip("\r\n") == SKIP:
        continue
    sys.stdout.write(line)
