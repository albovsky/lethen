#!/bin/bash
# Compares a project's latest canonical findings with the committed expectation.
# An expectation recorded before rows carried a confidence field (seven fields per row) is compared
# without that field, so it still diffs row for row.
# Usage: corpus/diff.sh <name>   Exit status 1 when they differ.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
name="${1:?usage: corpus/diff.sh <name>}"
expected="$root/corpus/expected/$name.json"
actual="$root/.corpus/results/$name.canonical.json"
if python3 - "$expected" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1]))
sys.exit(0 if rows and all(len(row) == 7 for row in rows) else 1)
PY
then
    trimmed="$(mktemp)"
    trap 'rm -f "$trimmed"' EXIT
    python3 - "$actual" > "$trimmed" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1]))
print("[\n" + ",\n".join(json.dumps(row[:7]) for row in rows) + "\n]")
PY
    actual="$trimmed"
fi
diff -u "$expected" "$actual"
