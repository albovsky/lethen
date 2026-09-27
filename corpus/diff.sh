#!/bin/bash
# Compares a project's latest canonical findings with the committed expectation.
# Usage: corpus/diff.sh <name>   Exit status 1 when they differ.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
name="${1:?usage: corpus/diff.sh <name>}"
diff -u "$root/corpus/expected/$name.json" "$root/.corpus/results/$name.canonical.json"
