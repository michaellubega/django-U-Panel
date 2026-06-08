#!/usr/bin/env python3
"""Build Word documents from U-Panel technical markdown sources."""

from __future__ import annotations

import sys
from pathlib import Path

DOCS = Path(__file__).resolve().parent

# Reuse the markdown → docx converter from the check-in report builder.
sys.path.insert(0, str(DOCS))
from _build_check_in_report_docx import build_docx  # noqa: E402

SOURCES = (
    ("U_PANEL_ALGORITHMS.md", "U_PANEL_ALGORITHMS.docx"),
    ("U_PANEL_ARCHITECTURE.md", "U_PANEL_ARCHITECTURE.docx"),
)


def main() -> None:
    for md_name, docx_name in SOURCES:
        md_path = DOCS / md_name
        out_path = DOCS / docx_name
        if not md_path.is_file():
            raise SystemExit(f"Missing {md_path}")
        build_docx(md_path.read_text(encoding="utf-8"), out_path)
    print("Done. Word files:")
    for _, docx_name in SOURCES:
        print(f"  {DOCS / docx_name}")


if __name__ == "__main__":
    main()
