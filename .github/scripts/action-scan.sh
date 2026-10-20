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
# With strict on and no min-confidence input, the step fails only on `certain` results.
# In the github-actions format the scan still reports every result, so `likely` ones stay
# visible as notices, and the count is that of the `certain` results' warnings; in other
# formats the scan runs with `--min-confidence certain`, when the binary has the option.
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
min_confidence="${LETHEN_MIN_CONFIDENCE:-}"
count_warnings=false
if [ -z "$min_confidence" ] && [ "$strict" = true ]; then
    if [ "$format" = github-actions ]; then
        count_warnings=true
    elif "$binary" scan --help 2>/dev/null | grep -q -- '--min-confidence'; then
        min_confidence=certain
    fi
fi
if [ -n "$min_confidence" ]; then
    command+=(--min-confidence "$min_confidence")
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
# The prefix becomes part of each annotation's `file` property, so it is escaped as lethen
# escapes property values, or a comma, colon or newline in a directory name would end the
# property or the command. It is then escaped for the replacement side of the sed expression.
property="${prefix//\%/%25}"
property="${property//$'\r'/%0D}"
property="${property//$'\n'/%0A}"
property="${property//:/%3A}"
property="${property//,/%2C}"
escaped_prefix="$(printf '%s' "$property" | sed 's/[\\&|]/\\&/g')"
annotate() {
    sed -e "s|^::warning file=|::warning file=$escaped_prefix|" -e "s|^::notice file=|::notice file=$escaped_prefix|"
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

total="$count"
if [ "$count_warnings" = true ] && [ "$count" -gt 0 ]; then
    # One warning per `certain` result, except that a redundant protocol adds one for each
    # conformance. The properties escape `:`, so the message follows the first `::` after
    # the command.
    warnings="$(grep -cE '^::warning [^:]*::' "$results_file" || true)"
    conformances="$(grep -cE "^::warning [^:]*::Redundant protocol conformance '" "$results_file" || true)"
    count=$((warnings - conformances))
fi

{
    echo "results-file=$results_file"
    echo "count=$count"
} >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

results() { if [ "$1" -eq 1 ]; then echo result; else echo results; fi; }
if [ "$total" -gt "$count" ]; then
    likely=$((total - count))
    echo "Lethen reported $likely likely $(results "$likely"), annotated as notices; set min-confidence to likely to fail the step on them."
fi
if [ "$count" -eq 0 ]; then
    echo "Lethen reported no $([ "$total" -gt 0 ] && echo "certain ")results."
elif [ "$strict" = true ]; then
    fail "Lethen reported $count $(results "$count")."
else
    echo "Lethen reported $count $(results "$count"); strict is false, so the step passes."
fi
