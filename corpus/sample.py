#!/usr/bin/env python3
"""Print a corpus project's adjudication sample as Markdown table rows.

A finding is sampled when the hash of its key falls under the project's `sample_rate` in
corpus/adjudications/<project>.json, so a finding that survives an analysis change keeps its
membership and its verdict. Rows show the committed verdict, or are left blank when one is needed.

Usage:
  corpus/sample.py <project>             every sampled finding
  corpus/sample.py <project> --pending   only sampled findings without a verdict, as JSON entries
                                         to complete and add to corpus/adjudications/<project>.json
  corpus/sample.py <project> --seed 2026 the positional draw the first scorecard used (30 rows from
                                         the sorted findings); pass --expected with the expectation
                                         of that time to reproduce its table
"""
import argparse
import json
import random
import sys
from pathlib import Path

from precision import CorpusError, is_sampled, load_adjudications, load_expected


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("name")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent, help=argparse.SUPPRESS)
    parser.add_argument("--pending", action="store_true", help="print sampled findings without a verdict as JSON entries")
    parser.add_argument("--seed", type=int, help="use the original positional draw with this seed")
    parser.add_argument("--count", type=int, default=30, help="rows in the positional draw")
    parser.add_argument("--expected", type=Path, help="with --seed, read findings from this file")
    args = parser.parse_args(argv)

    if args.seed is not None:
        rows = json.loads((args.expected or args.root / f"corpus/expected/{args.name}.json").read_text())
        rows.sort(key=json.dumps)
        sample = random.Random(args.seed).sample(rows, min(args.count, len(rows)))
        for index, (path, line, column, kind, name, hints, ids) in enumerate(sample, 1):
            print(f"| {args.name}-{index} | `{path}:{line}` | {kind} `{name}` | {', '.join(hints)} | | |")
        return 0
    if args.expected or args.count != 30:
        parser.error("--expected and --count apply only to --seed")

    try:
        rate, verdicts = load_adjudications(args.root, args.name)
    except CorpusError as error:
        print(f"corpus: {error}", file=sys.stderr)
        return 2
    rows = json.loads((args.root / f"corpus/expected/{args.name}.json").read_text())
    sampled = [row for row, key in zip(rows, load_expected(args.root, args.name)) if is_sampled(args.name, key, rate)]
    for path, line, column, kind, name, hints, ids in sampled:
        entry = verdicts.get((path, line, column, kind, name))
        if args.pending:
            if entry is None:
                stub = {"path": path, "line": line, "column": column, "kind": kind, "name": name,
                        "verdict": "", "note": "", "adjudicated_on": "", "lethen_commit": ""}
                print(json.dumps(stub, ensure_ascii=False) + ",")
        elif entry is None:
            print(f"| `{path}:{line}:{column}` | {kind} `{name}` | {', '.join(hints)} | | |")
        else:
            print(f"| `{path}:{line}:{column}` | {kind} `{name}` | {', '.join(hints)} | {entry['verdict']} | {entry['note']} |")
    return 0


if __name__ == "__main__":
    sys.exit(main())
