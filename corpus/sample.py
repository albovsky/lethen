#!/usr/bin/env python3
"""Print a deterministic sample of a corpus project's expected findings for adjudication."""
import argparse
import json
import random
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("name")
parser.add_argument("--seed", type=int, default=2026)
parser.add_argument("--count", type=int, default=30)
args = parser.parse_args()

root = Path(__file__).resolve().parent
rows = json.loads((root / "expected" / f"{args.name}.json").read_text())
rows.sort(key=json.dumps)
sample = random.Random(args.seed).sample(rows, min(args.count, len(rows)))
for index, (path, line, column, kind, name, hints, ids) in enumerate(sample, 1):
    print(f"| {args.name}-{index} | `{path}:{line}` | {kind} `{name}` | {', '.join(hints)} | | |")
