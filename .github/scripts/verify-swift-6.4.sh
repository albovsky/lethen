#!/bin/bash
# Verifies the required Swift 6.4 / Xcode 27 baseline. With no argument it runs all of
# it, which is what contributors run locally. CI runs it as two jobs on separate runners
# so they finish sooner: `spm` runs the SPMTests target alone, the slowest one, and
# `main` runs every other test target and all the scans.
set -euo pipefail
part="${1:-all}"
case "$part" in
  all | main | spm) ;;
  *) echo "usage: $0 [all|main|spm]" >&2; exit 2 ;;
esac
mkdir -p .validation
{
  sw_vers
  uname -m
  xcodebuild -version
  swift --version
  xcodebuild -showsdks
  env | sort | sed -n '/^ImageOS=/p; /^ImageVersion=/p'
  git rev-parse HEAD
} > .validation/toolchain.txt 2>&1
swift --version | grep -E 'Apple Swift version 6\.4([ .]|$)'
xcodebuild -version | grep -E '^Xcode 27\.0$'
swift build --product lethen 2>&1 | tee .validation/build.log
case "$part" in
  all) swift test 2>&1 | tee .validation/test.log ;;
  main) swift test --skip '^SPMTests\.' 2>&1 | tee .validation/test.log ;;
  spm)
    swift test --filter '^SPMTests\.' 2>&1 | tee .validation/test.log
    exit 0
    ;;
esac
lethen_bin_dir="$(swift build --show-bin-path)"
lethen_bin="$lethen_bin_dir/lethen"
{
  printf '%s\n' "$lethen_bin"
  shasum -a 256 "$lethen_bin"
  "$lethen_bin" version
} > .validation/binary.txt

for mode in clean warm native; do
  scan_arguments=(scan --project-root Tests/Fixtures --quiet --disable-update-check --format json --relative-results)
  if [ "$mode" = warm ]; then scan_arguments+=(--skip-build); else scan_arguments+=(--clean-build); fi
  if [ "$mode" = native ]; then scan_arguments+=(-- --build-system native); fi
  "$lethen_bin" "${scan_arguments[@]}" \
    > ".validation/fixtures-$mode.json" 2> ".validation/fixtures-$mode.log"
  python3 .github/scripts/canonicalize-scan-json.py Tests/Fixtures \
    ".validation/fixtures-$mode.json" > ".validation/fixtures-$mode.canonical.json"
done
diff -u .validation/fixtures-clean.canonical.json .validation/fixtures-warm.canonical.json \
  > .validation/fixtures-clean-warm.diff
diff -u .validation/fixtures-clean.canonical.json .validation/fixtures-native.canonical.json \
  > .validation/fixtures-default-native.diff
"$lethen_bin" scan --quiet --clean-build --strict --disable-update-check \
  > .validation/self-scan.log 2>&1
