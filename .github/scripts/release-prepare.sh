#!/usr/bin/env bash
# Decides whether a tag may be released, before anything is built or signed.
#
# A tag is releasable when it names a version (`3.9.0`, or `3.9.0-dev.1` for a
# prerelease), matches `PeripheryVersion` in the tagged source, points at a commit on
# master, and that commit passed the `Required checks` gate. The gate usually still runs
# when a tag is pushed right after a merge, so this waits for it instead of failing; a
# completed gate with any result other than success fails at once.
#
# Inputs (environment): RELEASE_TAG, GH_TOKEN with `checks: read`, GH_REPO (owner/name),
# and optionally RELEASE_CI_TIMEOUT_MINUTES (default 120). Run from a full-history
# checkout. Writes tag, sha, and prerelease to $GITHUB_OUTPUT when it is set.
set -euo pipefail

tag="${RELEASE_TAG:?RELEASE_TAG is required}"
repo="${GH_REPO:?GH_REPO is required}"
timeout_minutes="${RELEASE_CI_TIMEOUT_MINUTES:-120}"

fail() {
    echo "::error::$1" >&2
    exit 1
}

if [[ ! "$tag" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z]+(\.[0-9A-Za-z]+)*)?$ ]]; then
    fail "Tag '$tag' is not a release version such as 3.9.0 or 3.9.0-dev.1."
fi

if ! sha="$(git rev-parse --verify --quiet "refs/tags/$tag^{commit}")"; then
    fail "Tag '$tag' does not exist."
fi

source_version="$(git show "$sha:Sources/Frontend/Version.swift" | sed -n 's/^let PeripheryVersion = "\(.*\)"$/\1/p')"
if [ "$source_version" != "$tag" ]; then
    fail "Tag '$tag' does not match PeripheryVersion '$source_version' in Sources/Frontend/Version.swift."
fi

git fetch --quiet origin master
if ! git merge-base --is-ancestor "$sha" origin/master; then
    fail "Tag '$tag' points at $sha, which is not on master."
fi

echo "Waiting up to $timeout_minutes minutes for Required checks on $sha"
deadline=$((SECONDS + timeout_minutes * 60))
while true; do
    # Reruns add check runs, so the newest one is the gate's current result.
    latest="$(gh api "repos/$repo/commits/$sha/check-runs?check_name=Required%20checks&filter=latest" \
        --jq '.check_runs | sort_by(.started_at) | last | if . == null then "missing" else "\(.status) \(.conclusion)" end')"
    case "$latest" in
        "completed success")
            echo "Required checks passed on $sha"
            break
            ;;
        completed*)
            fail "Required checks finished as '${latest#completed }' on $sha; fix or rerun them before releasing."
            ;;
    esac
    if [ "$SECONDS" -ge "$deadline" ]; then
        fail "Required checks did not finish on $sha within $timeout_minutes minutes (last state: $latest)."
    fi
    echo "Required checks: $latest; checking again in 60 seconds"
    sleep 60
done

prerelease=false
if [[ "$tag" == *-* ]]; then
    prerelease=true
fi

echo "Releasing $tag from $sha (prerelease: $prerelease)"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        echo "tag=$tag"
        echo "sha=$sha"
        echo "prerelease=$prerelease"
    } >> "$GITHUB_OUTPUT"
fi
