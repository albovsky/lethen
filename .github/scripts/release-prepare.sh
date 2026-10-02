#!/usr/bin/env bash
# Decides whether a tag may be released, before anything is built or signed.
#
# A tag is releasable when it names a version (`2026.10.1`, the year, the month without a
# leading zero, and the release number within that month, or `2026.10.1-dev.1` for a
# prerelease; tags through 3.10.0 were `3.10.0`), matches `LethenVersion` in the tagged source, points at a commit on
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

# Semantic Versioning forbids leading zeros, so 2026.09.1 is rejected; write 2026.9.1.
if [[ ! "$tag" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z]+(\.[0-9A-Za-z]+)*)?$ ]]; then
    fail "Tag '$tag' is not a release version such as 2026.10.1 or 2026.10.1-dev.1 (year, month without a leading zero, release number)."
fi

# Numeric prerelease identifiers must not have leading zeros either (2026.10.1-dev.01).
prerelease_part="${tag#*-}"
if [[ "$tag" == *-* ]] && printf '%s\n' "$prerelease_part" | tr '.' '\n' | grep -Eq '^0[0-9]+$'; then
    fail "Tag '$tag' has a numeric prerelease identifier with a leading zero."
fi

# Releases after 3.10.0 are calendar versions: 2026 or later, month 1 to 12, release number 1 or more.
# Earlier tags (3.8.1, 3.10.0) stay releasable so a backfill can still run.
IFS=. read -r major minor patch_and_pre <<< "$tag"
patch="${patch_and_pre%%-*}"
if (( major >= 2000 )); then
    if (( major < 2026 || minor < 1 || minor > 12 || patch < 1 )); then
        fail "Tag '$tag' is not a calendar version: expected YYYY.M.N with a year of 2026 or later, a month from 1 to 12, and a release number of 1 or more."
    fi
elif (( major > 3 || (major == 3 && (minor > 10 || (minor == 10 && patch > 0))) )); then
    fail "Tag '$tag' is neither a calendar version (YYYY.M.N, such as 2026.10.1) nor a release through 3.10.0."
fi

if ! sha="$(git rev-parse --verify --quiet "refs/tags/$tag^{commit}")"; then
    fail "Tag '$tag' does not exist."
fi

source_version="$(git show "$sha:Sources/Frontend/Version.swift" | sed -n 's/^let LethenVersion = "\(.*\)"$/\1/p')"
if [ "$source_version" != "$tag" ]; then
    fail "Tag '$tag' does not match LethenVersion '$source_version' in Sources/Frontend/Version.swift."
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
