#!/usr/bin/env python3
"""Inline dashboard/data.json into dashboard/template.html -> dashboard/index.html.

The dashboard ships as one self-contained file with no network requests, so it
can be opened from disk, served by the compose stack, or published as-is.

    make dashboard      # export data + build
    python3 tools/build_dashboard.py
"""
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TEMPLATE = ROOT / "dashboard" / "template.html"
DATA = ROOT / "dashboard" / "data.json"
OUT = ROOT / "dashboard" / "index.html"

PLACEHOLDER = "/*__DATA__*/ null"


def main() -> int:
    if not DATA.exists():
        print(f"missing {DATA} — run the export first (make dashboard)", file=sys.stderr)
        return 1

    payload = json.loads(DATA.read_text())
    template = TEMPLATE.read_text()

    if PLACEHOLDER not in template:
        print("template has no data placeholder", file=sys.stderr)
        return 1

    # Separators without spaces keep the inlined payload compact; "</" is escaped
    # so a string in the data can never close the surrounding <script> element.
    compact = json.dumps(payload, separators=(",", ":")).replace("</", "<\\/")
    OUT.write_text(template.replace(PLACEHOLDER, compact))

    size = OUT.stat().st_size
    counts = {k: (len(v) if isinstance(v, list) else v)
              for k, v in payload.items() if k in ("scorecard", "programs", "dq_flags", "lineage")}
    print(f"wrote {OUT.relative_to(ROOT)}  ({size/1024:.0f} KB)  rows: {counts}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
