#!/usr/bin/env python3
"""Canonicalize scanner findings without hiding declaration kinds or hint categories."""
import json
from pathlib import Path
import sys

root = Path(sys.argv[1]).resolve()
with open(sys.argv[2], encoding="utf-8") as source:
    findings = json.load(source)

rows = set()
for finding in findings:
    path, line, column = finding["location"].rsplit(":", 2)
    if Path(path).is_absolute():
        try:
            path = str(Path(path).relative_to(root))
        except ValueError:
            pass  # An external path is evidence, not something to discard.
    rows.add((path, int(line), int(column), finding["kind"], finding.get("name"),
              tuple(sorted(finding["hints"])), tuple(sorted(finding["ids"]))))

json.dump(sorted(rows, key=lambda row: json.dumps(row)), sys.stdout, indent=2)
sys.stdout.write("\n")
