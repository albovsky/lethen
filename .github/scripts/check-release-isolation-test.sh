#!/usr/bin/env bash
# Runs check-release-isolation.sh against the Release workflow and against copies of it
# changed in ways that must fail: every way a job can reach a secret or a write token, and
# every way the release binary can move into a privileged job. Controls that must pass keep
# the check from failing on harmless text. `mise run lint-ci` runs this test.
#
# Usage: check-release-isolation-test.sh [workflow-file]

# The Ruby snippets hold literal `${{ }}` workflow expressions, which the shell must not expand.
# shellcheck disable=SC2016
set -euo pipefail

workflow="${1:-.github/workflows/release.yml}"
check="$(dirname "$0")/check-release-isolation.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
failures=0

# Writes the workflow with one change applied by the Ruby snippet $2 (`w` is the workflow).
mutate() {
    ruby -ryaml -e '
        w = YAML.safe_load(File.read(ARGV[0]), aliases: true)
        smoke = w["jobs"]["smoke-test"]
        publish = w["jobs"]["publish"]
        sign = w["jobs"]["sign"]
        eval(ARGV[1])
        File.write(ARGV[2], w.to_yaml)
    ' "$workflow" "$1" "$work/release.yml"
}

expect() {
    local expected="$1" name="$2" change="$3"
    mutate "$change"
    if bash "$check" "$work/release.yml" > /dev/null 2>&1; then actual=pass; else actual=fail; fi
    if [ "$actual" = "$expected" ]; then
        echo "ok: $name ($actual)"
    else
        echo "::error::check-release-isolation.sh should $expected when $name, but it did $actual" >&2
        failures=$((failures + 1))
    fi
}

expect pass "the workflow is unchanged" ''
expect pass "a smoke-test step mentions secrets in plain text" 'smoke["steps"] << { "run" => "echo no secrets here" }'
expect pass "a smoke-test step uses the read-only job token" 'smoke["steps"][0]["env"] = { "T" => "${{ github.token }}" }'
expect pass "brew test runs in the unprivileged smoke-test job" 'smoke["steps"] << { "run" => "brew test lethen" }'

expect fail "smoke-test reads secrets.NAME" 'smoke["steps"][0]["env"] = { "T" => "${{ secrets.HOMEBREW_TAP_TOKEN }}" }'
expect fail "smoke-test reads secrets[\"NAME\"]" "smoke[\"steps\"][0][\"env\"] = { \"T\" => \"\${{ secrets['HOMEBREW_TAP_TOKEN'] }}\" }"
expect fail "smoke-test reads toJSON(secrets)" 'smoke["env"]["ALL"] = "${{ toJSON(secrets) }}"'
expect fail "smoke-test inherits secrets" 'smoke["secrets"] = "inherit"'
expect fail "the workflow env reads a secret" 'w["env"] = (w["env"] || {}).merge("T" => "${{ secrets.HOMEBREW_TAP_TOKEN }}")'
expect fail "smoke-test gets the release environment" 'smoke["environment"] = "release"'
expect fail "smoke-test can write contents" 'smoke["permissions"] = { "contents" => "write" }'
expect fail "smoke-test gets write-all" 'smoke["permissions"] = "write-all"'
expect fail "smoke-test gets id-token: write" 'smoke["permissions"] = { "contents" => "read", "id-token" => "write" }'
expect fail "smoke-test has no permissions anywhere" 'smoke.delete("permissions"); w.delete("permissions")'
expect fail "publish runs the smoke test" 'publish["steps"] << { "run" => "bash tools/.github/scripts/release-smoke-test.sh released/lethen x" }'
expect fail "publish runs brew install" 'publish["steps"] << { "run" => "brew install --formula lethen" }'
expect fail "sign runs brew reinstall" 'sign["steps"] << { "run" => "brew reinstall lethen" }'
expect fail "publish runs the formula test" 'publish["steps"] << { "run" => "bash tools/.github/scripts/release-homebrew.sh test x y" }'

if [ "$failures" -ne 0 ]; then
    exit 1
fi
echo "check-release-isolation.sh caught every mutation"
