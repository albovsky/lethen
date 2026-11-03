#!/usr/bin/env bash
# Runs action-scan.sh against a stand-in for lethen that reports one `certain` result, one
# `likely` result and one `certain` redundant protocol with two conformances, and checks the
# arguments the scan gets, the step's outcome, its `count` output and the annotations, for
# the empty, `certain` and `likely` min-confidence inputs with strict on and off. `mise run
# lint-ci` runs this test.
#
# Usage: action-scan-test.sh
set -euo pipefail

script="$(cd "$(dirname "$0")" && pwd)/action-scan.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

# The stand-in prints the results in the github-actions format or, for any other format, one
# line per result, honours --min-confidence and --strict as lethen does, and records its
# arguments. With FAKE_OLD set it is a lethen without --min-confidence.
cat > "$work/lethen" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${2:-}" = --help ]; then
    echo "USAGE: lethen scan [<options>]"
    if [ -z "${FAKE_OLD:-}" ]; then echo "  --min-confidence <min-confidence>"; fi
    # A help producer must be able to finish writing after the matching option.
    awk 'BEGIN { for (i=0; i<16000; i++) print "  another scan option" }'
    exit 0
fi
printf '%s\n' "$@" > "$FAKE_ARGUMENTS"
format="" results_file="" min_confidence=likely strict=false
while [ $# -gt 0 ]; do
    case "$1" in
        --format) format="$2"; shift ;;
        --write-results) results_file="$2"; shift ;;
        --min-confidence) [ -z "${FAKE_OLD:-}" ] || { echo "Error: Unknown option '--min-confidence'" >&2; exit 64; }; min_confidence="$2"; shift ;;
        --strict) strict=true ;;
    esac
    shift
done
{
    if [ "$format" = github-actions ]; then
        severity=notice
        if [ -n "${FAKE_310:-}" ]; then severity=warning; fi
        if [ "$min_confidence" != certain ]; then
            echo "::$severity file=Sources/B.swift,line=2,col=6,title=redundantProtocol::Redundant protocol 'B' (never used as an existential type) [likely: its name appears in a string literal]"
            echo "::$severity file=Sources/U.swift,line=1,col=8,title=redundantProtocol::Redundant protocol conformance 'B'"
        fi
        if [ -z "${FAKE_ONLY_LIKELY:-}" ]; then
            echo "::warning file=Sources/A.swift,line=1,col=6,title=unused::Unused function 'a()'"
            echo "::warning file=Sources/P.swift,line=1,col=10,title=redundantProtocol::Redundant protocol 'P' (never used as an existential type)"
            echo "::warning file=Sources/S.swift,line=1,col=8,title=redundantProtocol::Redundant protocol conformance 'P'"
            echo "::warning file=Sources/T.swift,line=1,col=8,title=redundantProtocol::Redundant protocol conformance 'P'"
        fi
    else
        if [ -z "${FAKE_ONLY_LIKELY:-}" ]; then printf '%s\n' "certain a()" "certain P"; fi
        [ "$min_confidence" = certain ] || echo "likely b()"
    fi
} | tee "$results_file"
count=0
if [ -z "${FAKE_ONLY_LIKELY:-}" ]; then count=2; fi
if [ "$min_confidence" != certain ]; then count=$((count + 1)); fi
if [ "$strict" = true ] && [ "$count" -gt 0 ]; then echo "Error: Found $count issues." >&2; exit 1; fi
EOF
chmod +x "$work/lethen"
mkdir -p "$work/workspace/App" "$work/workspace/Apps & Tools"

# Runs the scan with the given strict and min-confidence inputs and the format, then compares
# the outcome, the count, whether --min-confidence reached lethen, and whether the `likely`
# result was annotated.
expect() {
    local name="$1" strict="$2" min_confidence="$3" format="$4" outcome="$5" count="$6" argument="$7" notice="$8"
    local prefix="${TEST_PREFIX-App/}"
    : > "$work/output"
    : > "$work/arguments"
    if (cd "$work/workspace/$prefix" && env LETHEN_BIN="$work/lethen" LETHEN_STRICT="$strict" LETHEN_MIN_CONFIDENCE="$min_confidence" \
        LETHEN_FORMAT="$format" GITHUB_WORKSPACE="$work/workspace" RUNNER_TEMP="$work" GITHUB_OUTPUT="$work/output" \
        FAKE_ARGUMENTS="$work/arguments" FAKE_OLD="${FAKE_OLD:-}" FAKE_310="${FAKE_310:-}" FAKE_ONLY_LIKELY="${FAKE_ONLY_LIKELY:-}" bash "$script") > "$work/log" 2>&1; then
        actual_outcome=pass
    else
        actual_outcome=fail
    fi
    actual_count="$(sed -n 's/^count=//p' "$work/output")"
    actual_argument="$(grep -A1 -x -- --min-confidence "$work/arguments" | tail -n 1 || true)"
    local results_file
    results_file="$(sed -n 's/^results-file=//p' "$work/output")"
    # Both the protocol and its conformance must have the same severity in each output.
    if [ "$(grep -Ec "^::notice file=${prefix}Sources/(B|U)[.]swift," "$work/log" || true)" = 2 ] &&
        [ "$(grep -Ec "^::notice file=${prefix}Sources/(B|U)[.]swift," "$results_file" || true)" = 2 ]; then
        actual_notice=yes
    else
        actual_notice=no
    fi
    if [ "$format" = github-actions ] && [ -z "${FAKE_ONLY_LIKELY:-}" ]; then
        for file in "$work/log" "$results_file"; do
            if [ "$(grep -Ec "^::warning file=${prefix}Sources/(A|P|S|T)[.]swift," "$file" || true)" != 4 ]; then
                echo "::error::$name did not keep all four certain annotations as warnings in $file" >&2
                failures=$((failures + 1))
            fi
        done
    fi
    local actual="$actual_outcome count=$actual_count min-confidence=${actual_argument:-none} notice=$actual_notice"
    local expected="$outcome count=$count min-confidence=$argument notice=$notice"
    if [ "$actual" = "$expected" ]; then
        echo "ok: $name ($actual)"
    else
        echo "::error::action-scan.sh with $name should give '$expected', but gave '$actual'" >&2
        sed 's/^/    /' "$work/log" >&2
        failures=$((failures + 1))
    fi
}

#      name                                        strict min    format         outcome count argument notice
expect "strict and no min-confidence"              true   ""     github-actions fail    2     none     yes
expect "strict and min-confidence certain"         true   certain github-actions fail   2     certain  no
expect "strict and min-confidence likely"          true   likely github-actions fail    3     likely   yes
expect "no strict and no min-confidence"           false  ""     github-actions pass    3     none     yes
expect "no strict and min-confidence certain"      false  certain github-actions pass   2     certain  no
expect "no strict and min-confidence likely"       false  likely github-actions pass    3     likely   yes
expect "strict, no min-confidence, json"           true   ""     json           fail    2     certain  no
expect "no strict, no min-confidence, json"        false  ""     json           pass    3     none     no
FAKE_OLD=1 expect "strict, json, a lethen without --min-confidence" true "" json fail 3 none no

FAKE_310=1 expect "3.10.0 mixed warnings" true "" github-actions fail 2 none yes

# Only `likely` results: the step passes on them and says so, and the count is 0.
FAKE_ONLY_LIKELY=1 expect "strict, no min-confidence, only likely results" true "" github-actions pass 0 none yes
grep -q '^Lethen reported 1 likely result, annotated as notices' "$work/log" \
    || { echo "::error::The step does not say that the likely result was not counted" >&2; failures=$((failures + 1)); }

FAKE_ONLY_LIKELY=1 FAKE_310=1 expect "3.10.0 only likely warnings" true "" github-actions pass 0 none yes

TEST_PREFIX="" expect "modern mixed findings at the repository root" true "" github-actions fail 2 none yes
TEST_PREFIX="" FAKE_310=1 expect "3.10.0 mixed findings at the repository root" true "" github-actions fail 2 none yes
TEST_PREFIX="Apps & Tools/" FAKE_310=1 expect "3.10.0 special-character path" true "" github-actions fail 2 none yes
FAKE_310=1 expect "3.10.0 non-strict warnings" false "" github-actions pass 3 none no

if [ "$failures" -gt 0 ]; then
    echo "$failures action-scan.sh expectations failed" >&2
    exit 1
fi
