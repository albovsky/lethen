#!/usr/bin/env bash
# Regression test for the FoundationNetworking teardown crash on Linux.
#
# The scan command starts a GitHub update check up front and used to read its result
# without waiting, so the URLSession could be invalidated mid-transfer. On Linux that
# aborted the process with SIGILL (exit 132) *after* an otherwise successful scan.
#
# This runs several scans with the update check enabled and requires every one to exit 0.
# The check itself is allowed to fail: an unreachable endpoint, a 404, or a rate-limit
# response all take the same handled error path, so this step fails only if the process
# dies during teardown.
#
# The crash is intermittent — roughly one run in five on Swift 6.1 — so the iteration
# count is deliberately high enough to make a surviving defect very likely to show up
# rather than pass by luck.
set -euo pipefail

binary="${1:-./.build/debug/lethen}"
iterations="${2:-15}"

if [ ! -x "$binary" ]; then
    echo "error: lethen binary not found at $binary" >&2
    exit 1
fi

binary="$(cd "$(dirname "$binary")" && pwd)/$(basename "$binary")"

workspace="$(mktemp -d)"
trap 'rm -rf "$workspace"' EXIT

mkdir -p "$workspace/Sources/UpdateCheckTeardown"
cat > "$workspace/Package.swift" <<'EOF'
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "UpdateCheckTeardown",
    targets: [.target(name: "UpdateCheckTeardown")]
)
EOF
cat > "$workspace/Sources/UpdateCheckTeardown/UpdateCheckTeardown.swift" <<'EOF'
public struct Retained {
    public init() {}
}

struct Unreferenced {}
EOF

status=0
for i in $(seq 1 "$iterations"); do
    set +e
    (cd "$workspace" && "$binary" scan --project-root "$workspace" --quiet) \
        > "$workspace/run.log" 2>&1
    exit_code=$?
    set -e

    if [ "$exit_code" -ne 0 ]; then
        signal=""
        if [ "$exit_code" -gt 128 ]; then
            signal=" (signal $((exit_code - 128)))"
        fi
        echo "iteration $i: scan exited $exit_code$signal with the update check enabled" >&2
        echo "--- output ---" >&2
        cat "$workspace/run.log" >&2
        echo "--- end output ---" >&2
        status=1
    else
        echo "iteration $i: ok"
    fi
done

if [ "$status" -ne 0 ]; then
    echo "FAIL: the update check can still crash or fail the scan" >&2
    exit 1
fi

echo "PASS: $iterations scans completed with the update check enabled"
