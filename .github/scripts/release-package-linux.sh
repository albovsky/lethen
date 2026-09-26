#!/usr/bin/env bash
# Packages a Linux lethen executable as a release tarball.
#
# The tarball holds one directory, lethen-<version>-linux-<arch>, with bin/lethen (the
# launcher in release-linux-launcher.sh), libexec/lethen/lethen (the stripped
# executable), and LICENSE.md. The executable is built with --static-swift-stdlib, so it
# needs no Swift runtime of its own, but it links libIndexStore.so from the user's
# toolchain; the launcher finds it. Nothing in the executable is patched.
#
# Usage: release-package-linux.sh <executable> <license> <version> <x86_64|aarch64> <output-dir>
set -euo pipefail

executable="${1:?usage: $0 <executable> <license> <version> <arch> <output-dir>}"
license="${2:?usage: $0 <executable> <license> <version> <arch> <output-dir>}"
version="${3:?usage: $0 <executable> <license> <version> <arch> <output-dir>}"
arch="${4:?usage: $0 <executable> <license> <version> <arch> <output-dir>}"
output_dir="${5:?usage: $0 <executable> <license> <version> <arch> <output-dir>}"

case "$arch" in
    x86_64) machine="Advanced Micro Devices X86-64" ;;
    aarch64) machine="AArch64" ;;
    *)
        echo "::error::Unsupported architecture $arch" >&2
        exit 1
        ;;
esac
# Captured first: `grep -q` stops reading early, and pipefail would then report
# readelf's broken pipe as a mismatch.
header="$(readelf -h "$executable" 2> /dev/null)"
if ! grep -q "Machine: *$machine" <<< "$header"; then
    echo "::error::$executable is not a $arch executable" >&2
    echo "$header" >&2
    exit 1
fi

name="lethen-$version-linux-$arch"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
stage="$work/$name"

install -D -m 755 "$executable" "$stage/libexec/lethen/lethen"
strip "$stage/libexec/lethen/lethen"
install -D -m 755 "$(dirname "$0")/release-linux-launcher.sh" "$stage/bin/lethen"
install -m 644 "$license" "$stage/LICENSE.md"

mkdir -p "$output_dir"
tar -C "$work" --owner=0 --group=0 --numeric-owner -czf "$output_dir/$name.tar.gz" "$name"
echo "Packaged $output_dir/$name.tar.gz"
tar -tvzf "$output_dir/$name.tar.gz"
