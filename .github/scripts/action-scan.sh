#!/usr/bin/env bash
# Runs `lethen scan` for the GitHub Action (action.yml) from the step's working directory and
# writes the `results-file` and `count` outputs.
#
# The scan always runs with --strict, whose "Found N issues." error is how lethen reports the
# number of results in every output format, and the action then passes or fails the step by
# its own `strict` input. That line is replaced in the log by the action's own summary,
# because it would read as a failure when strict is false. Any other failure of the scan
# fails the step.
#
# lethen makes result paths relative to the directory it scans, but GitHub resolves
# annotation paths from the repository root, so for the github-actions format the working
# directory's path inside GITHUB_WORKSPACE is prefixed to each annotation, on the log and
# in the results file alike.
#
# The script sticks to bash 3.2, which is /bin/bash on macOS runners.
#
# Environment: LETHEN_BIN, LETHEN_ARGS, LETHEN_BASELINE, LETHEN_STRICT, LETHEN_FORMAT,
# LETHEN_MIN_CONFIDENCE, GITHUB_WORKSPACE, RUNNER_TEMP, GITHUB_OUTPUT.
set -euo pipefail

binary="${LETHEN_BIN:?LETHEN_BIN is required}"
format="${LETHEN_FORMAT:-github-actions}"
strict="${LETHEN_STRICT:-true}"

fail() {
    echo "::error::$1" >&2
    exit 1
}

case "$strict" in
    true | false) ;;
    *) fail "The strict input must be true or false, not '$strict'." ;;
esac

case "$format" in
    json | codeclimate | gitlab-codequality) extension=json ;;
    csv) extension=csv ;;
    checkstyle) extension=xml ;;
    github-markdown) extension=md ;;
    *) extension=txt ;;
esac

output="$(mktemp -d "${RUNNER_TEMP:-/tmp}/lethen-scan.XXXXXX")"
results_file="$output/results.$extension"
errors="$output/stderr.log"

command=("$binary" scan --format "$format" --relative-results --disable-update-check --strict --write-results "$results_file")
if [ -n "${LETHEN_BASELINE:-}" ]; then
    command+=(--baseline "$LETHEN_BASELINE")
fi
if [ -n "${LETHEN_MIN_CONFIDENCE:-}" ]; then
    command+=(--min-confidence "$LETHEN_MIN_CONFIDENCE")
fi
# The args input is parsed with shell quoting, as it would be on a command line.
extra=()
eval "extra=(${LETHEN_ARGS:-})"
command+=(${extra[@]+"${extra[@]}"})

prefix=""
if [ "$format" = github-actions ] && [ -n "${GITHUB_WORKSPACE:-}" ]; then
    here="$(pwd -P)"
    workspace="$(cd "$GITHUB_WORKSPACE" && pwd -P)"
    case "$here" in
        "$workspace"/*) prefix="${here#"$workspace"/}/" ;;
    esac
fi
# Escaped for the replacement side of the sed expression below.
escaped_prefix="$(printf '%s' "$prefix" | sed 's/[\\&|]/\\&/g')"
annotate() {
    sed "s|^::warning file=|::warning file=$escaped_prefix|"
}

echo "Running ${command[*]}"
# Standard output (the results) goes through `annotate`; standard error is shown as it
# arrives and kept for the result count. With pipefail, the status is lethen's own unless
# a filter itself fails.
set +e
{ "${command[@]}" 2>&1 1>&3 3>&- | tee "$errors" | sed -E '/^(Error: )?Found [0-9]+ issues?\.$/d' >&2; } 3>&1 | annotate
status=$?
set -e

if [ -n "$prefix" ] && [ -f "$results_file" ]; then
    annotate < "$results_file" > "$results_file.annotated"
    mv "$results_file.annotated" "$results_file"
fi

count=0
if [ "$status" -ne 0 ]; then
    found="$(sed -En 's/^(Error: )?Found ([0-9]+) issues?\.$/\2/p' "$errors" | tail -n 1)"
    if [ -z "$found" ]; then
        # The filtered log hid nothing but the count line, so everything lethen said is shown.
        fail "lethen scan failed with exit status $status."
    fi
    count="$found"
fi

{
    echo "results-file=$results_file"
    echo "count=$count"
} >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

if [ "$count" -eq 0 ]; then
    echo "Lethen reported no results."
elif [ "$strict" = true ]; then
    fail "Lethen reported $count $([ "$count" -eq 1 ] && echo result || echo results)."
else
    echo "Lethen reported $count $([ "$count" -eq 1 ] && echo result || echo results); strict is false, so the step passes."
fi
