#!/usr/bin/env bash
# Chooses the CI profile for a run and reports whether it changed anything besides
# documentation. Jobs read both values from the `changes` job's outputs.
#
# Profiles:
#   pr       pull requests: the newest stable toolchain per platform, so a PR queues
#            three macOS jobs instead of eight against the five-slot macOS limit
#   master   pushes to master: every stable toolchain
#   nightly  schedule and manual runs: the stable matrix plus main-snapshot toolchains
#
# `code` is false only when every changed file is documentation (`*.md` or `docs/`),
# in which case the build jobs are skipped and the required gate passes on their
# skipped results. Whenever the diff cannot be determined, everything runs.
#
# Inputs (environment): GITHUB_EVENT_NAME, and per event PR_BASE_SHA (pull_request),
# PUSH_BEFORE_SHA (push) or INPUT_PROFILE (workflow_dispatch). Requires full history.
set -euo pipefail

event="${GITHUB_EVENT_NAME:?GITHUB_EVENT_NAME is required}"
case "$event" in
    pull_request) profile=pr ;;
    push) profile=master ;;
    schedule) profile=nightly ;;
    workflow_dispatch) profile="${INPUT_PROFILE:-nightly}" ;;
    *)
        echo "error: unsupported event '$event'" >&2
        exit 1
        ;;
esac

case "$profile" in
    pr | master | nightly) ;;
    *)
        echo "error: unknown profile '$profile'" >&2
        exit 1
        ;;
esac

is_documentation() {
    case "$1" in
        *.md | docs/*) return 0 ;;
        *) return 1 ;;
    esac
}

base=""
case "$event" in
    pull_request) base="${PR_BASE_SHA:-}" ;;
    push) base="${PUSH_BEFORE_SHA:-}" ;;
esac

code=true
if [ -n "$base" ] && [ "$base" != "0000000000000000000000000000000000000000" ] \
    && git cat-file -e "$base^{commit}" 2> /dev/null \
    && merge_base="$(git merge-base "$base" HEAD 2> /dev/null)"; then
    changed="$(git diff --name-only "$merge_base" HEAD)"
    if [ -n "$changed" ]; then
        code=false
        while IFS= read -r file; do
            if ! is_documentation "$file"; then
                code=true
                break
            fi
        done <<< "$changed"
    fi
    echo "changed files since $merge_base:"
    printf '  %s\n' $changed
elif [ -n "$base" ]; then
    echo "base commit $base is unavailable; running every job"
else
    echo "$event runs every job"
fi

echo "profile=$profile"
echo "code=$code"
if [ -n "${GITHUB_OUTPUT:-}" ]; then
    {
        echo "profile=$profile"
        echo "code=$code"
    } >> "$GITHUB_OUTPUT"
fi
