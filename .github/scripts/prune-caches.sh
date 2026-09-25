#!/usr/bin/env bash
# Deletes Actions caches whose ref is gone: merged or closed pull requests and deleted
# branches. Those caches are never restored again, but they count against the 10 GB
# repository quota until GitHub evicts them, and eviction is least-recently-used across
# the whole repository, so live caches go with them and warm jobs turn cold at random.
#
# Usage: prune-caches.sh [--dry-run]
#
# Inputs (environment): GH_TOKEN with `actions: write`, and GH_REPO (owner/name; defaults
# to the checkout's repository). Refs other than branches, tags and pull requests are kept.
# Any lookup that fails for a reason other than "does not exist" aborts the run, so a
# transient API error never deletes a live cache.
set -euo pipefail

dry_run=false
case "${1:-}" in
    "") ;;
    --dry-run) dry_run=true ;;
    *)
        echo "usage: $0 [--dry-run]" >&2
        exit 2
        ;;
esac

repo="${GH_REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
caches="$(gh cache list --repo "$repo" --limit 1000 --json id,key,ref,sizeInBytes)"

# Prints "live" or "gone" for a ref.
ref_state() {
    local ref="$1" number state matches
    case "$ref" in
        refs/pull/*/merge | refs/pull/*/head)
            number="${ref#refs/pull/}"
            number="${number%%/*}"
            state="$(gh api "repos/$repo/pulls/$number" --jq .state)" \
                || { echo "error: could not look up pull request #$number" >&2; exit 1; }
            [ "$state" = "open" ] && echo live || echo gone
            ;;
        refs/heads/* | refs/tags/*)
            # matching-refs is a prefix search that answers 200 with [] for a missing ref,
            # so "gone" and "request failed" stay distinguishable.
            matches="$(gh api "repos/$repo/git/matching-refs/${ref#refs/}")" \
                || { echo "error: could not look up $ref" >&2; exit 1; }
            if jq -e --arg ref "$ref" 'any(.[]; .ref == $ref)' <<< "$matches" > /dev/null; then
                echo live
            else
                echo gone
            fi
            ;;
        *) echo live ;;
    esac
}

deleted=0
freed=0
while IFS= read -r ref; do
    [ -n "$ref" ] || continue
    state="$(ref_state "$ref")"
    size="$(jq --arg ref "$ref" '[.[] | select(.ref == $ref) | .sizeInBytes] | add' <<< "$caches")"
    count="$(jq --arg ref "$ref" '[.[] | select(.ref == $ref)] | length' <<< "$caches")"
    if [ "$state" = live ]; then
        echo "keep   $ref ($count caches, $((size / 1000000)) MB)"
        continue
    fi
    echo "delete $ref ($count caches, $((size / 1000000)) MB)"
    if [ "$dry_run" = false ]; then
        while IFS= read -r id; do
            gh cache delete "$id" --repo "$repo"
        done < <(jq -r --arg ref "$ref" '.[] | select(.ref == $ref) | .id' <<< "$caches")
    fi
    deleted=$((deleted + count))
    freed=$((freed + size))
done < <(jq -r '[.[].ref] | unique[]' <<< "$caches")

if [ "$dry_run" = true ]; then
    echo "dry run: would delete $deleted caches, $((freed / 1000000)) MB"
else
    echo "deleted $deleted caches, $((freed / 1000000)) MB"
fi
