#!/bin/bash
# Scans one corpus project at its pinned commit and writes its canonical findings to
# .corpus/results/<name>.canonical.json. Any clone, checkout, build or scan failure fails the run.
# Usage: corpus/scan.sh <name> [lethen-binary]
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
name="${1:?usage: corpus/scan.sh <name> [lethen-binary]}"
lethen="${2:-$(cd "$root" && swift build --show-bin-path)/lethen}"
manifest="$root/corpus/projects.json"

field() {
    python3 - "$manifest" "$name" "$1" <<'PY'
import json, sys
manifest, name, key = sys.argv[1:4]
entries = [e for e in json.load(open(manifest)) if e["name"] == name]
if not entries:
    sys.exit(f"corpus: unknown project '{name}'")
value = entries[0][key]
print("\n".join(value) if isinstance(value, list) else value)
PY
}

url="$(field url)"
commit="$(field commit)"
# macOS ships bash 3.2, which has no mapfile.
arguments=()
while IFS= read -r argument; do
    [ -n "$argument" ] && arguments+=("$argument")
done < <(field arguments)
checkouts="${CORPUS_CHECKOUTS:-$root/.corpus/checkouts}"
checkout="$checkouts/$name"
results="$root/.corpus/results"
mkdir -p "$checkouts" "$results"

if [ ! -d "$checkout/.git" ]; then
    git clone --quiet "$url" "$checkout"
fi
git -C "$checkout" fetch --quiet origin "$commit"
# --force discards edits a previous scan's build made; some projects' build phases run
# formatters over their sources (wikipedia-ios runs `swiftlint --fix`).
git -C "$checkout" checkout --quiet --force --detach "$commit"

"$lethen" scan --project-root "$checkout" --quiet --disable-update-check \
    --format json --relative-results ${arguments[@]+"${arguments[@]}"} > "$results/$name.json"
# One finding per line, so a changed finding is a one-line diff and expectations stay small.
python3 "$root/.github/scripts/canonicalize-scan-json.py" "$checkout" "$results/$name.json" \
    | python3 -c 'import json, sys; rows = json.load(sys.stdin); print("[\n" + ",\n".join(json.dumps(r) for r in rows) + "\n]")' \
    > "$results/$name.canonical.json"

# An empty result set is a broken scan until a human says otherwise.
if [ "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$results/$name.canonical.json")" = 0 ]; then
    echo "corpus: $name produced no findings; refusing to treat that as a result" >&2
    exit 1
fi
echo "corpus: $name -> $results/$name.canonical.json"
