#!/usr/bin/env bash
# Checks that a built lethen binary runs and finds unused code on this machine.
#
# The binary must report the release version, then scan a small generated package with
# one used and one unused function and report exactly the unused one. The scan builds the
# package with the active toolchain and loads its libIndexStore, so a pass also shows
# that the binary's library search paths resolve on this host. The package also has a
# class used only from a XIB, which stays unreported only if the binary's XML parser
# works.
#
# Usage: release-smoke-test.sh <binary> <expected-version>
set -euo pipefail

binary="${1:?usage: $0 <binary> <expected-version>}"
expected_version="${2:?usage: $0 <binary> <expected-version>}"

binary="$(cd "$(dirname "$binary")" && pwd)/$(basename "$binary")"

version="$("$binary" version)"
if [ "$version" != "$expected_version" ]; then
    echo "::error::lethen version printed '$version', expected '$expected_version'" >&2
    exit 1
fi
echo "lethen version: $version"

workspace="$(mktemp -d)"
trap 'rm -rf "$workspace"' EXIT

mkdir -p "$workspace/Sources/ReleaseSmoke"
cat > "$workspace/Package.swift" <<'EOF'
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ReleaseSmoke",
    targets: [.executableTarget(name: "ReleaseSmoke", resources: [.copy("View.xib")])]
)
EOF
cat > "$workspace/Sources/ReleaseSmoke/main.swift" <<'EOF'
func usedFunction() -> Int { 1 }
func unusedFunction() -> Int { 2 }
class XibView {}
print(usedFunction())
EOF
cat > "$workspace/Sources/ReleaseSmoke/View.xib" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<document type="com.apple.InterfaceBuilder3.CocoaTouch.XIB" version="3.0">
    <objects>
        <view contentMode="scaleToFill" id="view-1" customClass="XibView" customModule="ReleaseSmoke"/>
    </objects>
</document>
EOF

if ! (cd "$workspace" && "$binary" scan --project-root "$workspace" --format json --quiet --disable-update-check) \
    > "$workspace/results.json" 2> "$workspace/scan.log"; then
    echo "::error::lethen scan failed" >&2
    cat "$workspace/scan.log" >&2
    exit 1
fi

reported="$(jq -c '[.[].name] | sort' "$workspace/results.json")"
if [ "$reported" != '["unusedFunction()"]' ]; then
    echo "::error::lethen scan reported $reported, expected [\"unusedFunction()\"]" >&2
    cat "$workspace/results.json" >&2
    exit 1
fi
echo "lethen scan reported $reported"
