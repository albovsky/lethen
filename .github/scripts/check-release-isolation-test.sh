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
expect pass "the unprivileged smoke-test job runs the binary" 'smoke["steps"] << { "run" => "released/lethen version" }'
expect pass "the smoke-test job passes the binary through env" 'smoke["steps"] << { "env" => { "BINARY" => "released/lethen" }, "run" => "\"$BINARY\" version" }'
expect pass "a publish step is named after lethen" 'publish["steps"] << { "name" => "Publish lethen", "run" => "true" }'
expect pass "sign only passes the binary's path to other commands" 'sign["steps"] << { "run" => "chmod +x build/lethen\ncodesign --verify --strict build/lethen\nswift build --product lethen" }'

expect fail "smoke-test reads secrets.NAME" 'smoke["steps"][0]["env"] = { "T" => "${{ secrets.HOMEBREW_TAP_TOKEN }}" }'
expect fail "smoke-test reads secrets[\"NAME\"]" "smoke[\"steps\"][0][\"env\"] = { \"T\" => \"\${{ secrets['HOMEBREW_TAP_TOKEN'] }}\" }"
expect fail "smoke-test hides secrets behind a brace in a string" "smoke[\"env\"][\"T\"] = \"\${{ '}' && secrets.HOMEBREW_TAP_TOKEN }}\""
expect fail "smoke-test reads Secrets.NAME" 'smoke["env"]["T"] = "${{ Secrets.HOMEBREW_TAP_TOKEN }}"'
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
expect fail "sign runs build/lethen" 'sign["steps"] << { "run" => "build/lethen version" }'
expect fail "publish runs released/lethen" 'publish["steps"] << { "run" => "ditto -x -k dist/x.zip released\nreleased/lethen scan --quiet" }'
expect fail "publish runs a quoted path to the binary" 'publish["steps"] << { "run" => "\"$PWD/released/lethen\" version" }'
expect fail "sign runs the binary in a command substitution" 'sign["steps"] << { "run" => "v=$(./build/lethen version)" }'
expect fail "publish runs the binary after &&" 'publish["steps"] << { "run" => "cd released && ./lethen version" }'
expect fail "publish runs the binary through env" 'publish["steps"] << { "run" => "env -i HOME=/tmp released/lethen version" }'
expect fail "sign runs the binary through command" 'sign["steps"] << { "run" => "command build/lethen version" }'
expect fail "sign runs the binary through sudo" 'sign["steps"] << { "run" => "sudo -E build/lethen version" }'
expect fail "sign runs the binary through arch" 'sign["steps"] << { "run" => "arch -arm64 build/lethen version" }'
expect fail "publish opens the binary" 'publish["steps"] << { "run" => "open released/lethen" }'
expect fail "publish runs the binary through swift run" 'publish["steps"] << { "run" => "swift run lethen version" }'
expect fail "sign passes the binary to an unlisted repository script" 'sign["steps"] << { "run" => "bash tools/.github/scripts/run-lethen.sh build/lethen" }'
expect fail "sign passes the binary through a step env" 'sign["steps"] << { "env" => { "BINARY" => "build/lethen" }, "run" => "\"$BINARY\" version" }'
expect fail "publish passes the binary through the job env" 'publish["env"]["BINARY"] = "released/lethen"'
expect fail "sign passes the binary to an action input" 'sign["steps"] << { "uses" => "./.github/actions/run", "with" => { "binary" => "build/lethen" } }'
expect fail "the workflow env names the binary" 'w["env"] = (w["env"] || {}).merge("BINARY" => "build/lethen")'
expect fail "sign assigns the binary to a shell variable" 'sign["steps"] << { "run" => "b=build/lethen\n\"$b\" version" }'
expect fail "sign copies the binary and runs the copy" 'sign["steps"] << { "run" => "cp build/lethen /tmp/tool; /tmp/tool version" }'
expect fail "publish renames the binary" 'publish["steps"] << { "run" => "mv released/lethen /tmp/tool" }'
expect fail "sign links the binary" 'sign["steps"] << { "run" => "ln -s \"$PWD/build/lethen\" /tmp/tool" }'
expect fail "sign runs the binary in a process substitution" 'sign["steps"] << { "run" => "shasum <(build/lethen version)" }'
expect fail "sign runs the binary after a line continuation" 'sign["steps"] << { "run" => "true \\\n  && build/lethen version" }'
expect fail "publish runs the binary under if" 'publish["steps"] << { "run" => "if released/lethen version; then :; fi" }'
expect fail "sign passes the binary to a same-named script elsewhere" 'sign["steps"] << { "run" => "bash tools/other/release-sign-macos.sh build/lethen" }'
expect fail "sign passes the binary to a same-named script in /tmp" 'sign["steps"] << { "run" => "bash /tmp/release-sign-macos.sh build/lethen" }'
expect fail "sign runs the binary through split quoting" 'sign["steps"] << { "run" => "build/leth\"en\" version" }'
expect fail "sign runs the binary through ANSI-C quoting" "sign[\"steps\"] << { \"run\" => \"build/leth\$'en' version\" }"
expect fail "publish runs the binary through a backslash" 'publish["steps"] << { "run" => "released/leth\\en version" }'
expect fail "sign uses the binary as a step shell" 'sign["steps"][0]["shell"] = "build/lethen {0}"'
expect fail "publish sets the binary as the default shell" 'publish["defaults"] = { "run" => { "shell" => "released/lethen {0}" } }'
expect fail "the workflow sets the binary as the default shell" 'w["defaults"] = { "run" => { "shell" => "build/lethen {0}" } }'
expect fail "sign runs the binary with different letter case" 'sign["steps"] << { "run" => "build/LETHEN version" }'
expect fail "publish runs an installed lethen" 'publish["steps"] << { "run" => "lethen version" }'
expect fail "publish runs the formula test" 'publish["steps"] << { "run" => "bash tools/.github/scripts/release-homebrew.sh test x y" }'

# An exempt script that starts running its binary argument loses its exemption.
mkdir "$work/scripts"
cp "$(dirname "$0")"/*.sh "$work/scripts/"
mutate ''
if bash "$check" "$work/release.yml" "$work/scripts" > /dev/null 2>&1; then
    echo "ok: the exempt scripts only sign and inspect the binary (pass)"
else
    echo "::error::check-release-isolation.sh should pass with the repository's own scripts" >&2
    failures=$((failures + 1))
fi
# Each way an exempt script could run its binary argument must cost it the exemption.
for run in '"$binary" version' 'if "$binary" version; then :; fi' 'env -i "$binary" version' \
    'x="$("$binary" version)"' 'cat <("$binary" version)' 'codesign --sign - "$binary" && "${binary}" version' \
    '"$staging/lethen" version' 'cp "$binary" "$staging/tool"; "$staging/tool" version' \
    'tool="$staging/lethen"; "$tool" version' 'tool=$binary; "$tool" version'; do
    cp "$(dirname "$0")/release-sign-macos.sh" "$work/scripts/release-sign-macos.sh"
    printf '\n%s\n' "$run" >> "$work/scripts/release-sign-macos.sh"
    if bash "$check" "$work/release.yml" "$work/scripts" > /dev/null 2>&1; then
        echo "::error::check-release-isolation.sh should fail when release-sign-macos.sh runs $run, but it did pass" >&2
        failures=$((failures + 1))
    else
        echo "ok: release-sign-macos.sh runs $run (fail)"
    fi
done

if [ "$failures" -ne 0 ]; then
    exit 1
fi
echo "check-release-isolation.sh caught every mutation"
