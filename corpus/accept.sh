#!/bin/bash
# Records the latest canonical findings as the expectation. Only after adjudicating the diff.
# Usage: corpus/accept.sh <name>
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
name="${1:?usage: corpus/accept.sh <name>}"
mkdir -p "$root/corpus/expected"
cp "$root/.corpus/results/$name.canonical.json" "$root/corpus/expected/$name.json"
echo "corpus: accepted $name"
