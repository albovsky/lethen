#!/bin/bash
# Records the latest canonical findings as the expectation. Only after adjudicating the diff.
# Then lists the sampled findings that still need a verdict in corpus/adjudications/ and the
# verdicts whose findings are no longer reported; regenerate the scorecard with
# corpus/precision.py --markdown once they are recorded.
# Usage: corpus/accept.sh <name>
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
name="${1:?usage: corpus/accept.sh <name>}"
mkdir -p "$root/corpus/expected"
cp "$root/.corpus/results/$name.canonical.json" "$root/corpus/expected/$name.json"
echo "corpus: accepted $name"
status=0
python3 "$root/corpus/precision.py" --check || status=$?
# Status 1 means verdicts are still needed, which the listing names; anything else is an error.
[ "$status" -le 1 ] || exit "$status"
