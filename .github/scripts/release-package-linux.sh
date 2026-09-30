#!/usr/bin/env bash
# Packages a Linux lethen executable as a release tarball.
#
# The tarball holds one directory, lethen-<version>-linux-<arch>, with bin/lethen (the
# launcher in release-linux-launcher.sh), libexec/lethen/lethen (the stripped
# executable), LICENSE.md, and LICENSE-libxml2.txt. The executable is built with
# --static-swift-stdlib and a static libxml2 (release-build-libxml2.sh), so it needs no
# Swift runtime of its own, but it links libIndexStore.so from the user's toolchain; the
# launcher finds it. Nothing in the executable is patched.
#
# The executable may only need shared libraries whose names every supported distribution
# ships: glibc, libstdc++, libgcc_s, libcurl for FoundationNetworking, and libIndexStore.
# One that a newer release renamed, as Ubuntu 26.04 did with libxml2.so.16, would stop it
# from starting there.
#
# Usage: release-package-linux.sh <executable> <license> <version> <x86_64|aarch64> <output-dir> <libxml2-license>
set -euo pipefail

usage="usage: $0 <executable> <license> <version> <arch> <output-dir> <libxml2-license>"
executable="${1:?$usage}"
license="${2:?$usage}"
version="${3:?$usage}"
arch="${4:?$usage}"
output_dir="${5:?$usage}"
libxml2_license="${6:?$usage}"

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

dynamic="$(readelf -d "$executable")"
needed="$(sed -n 's/.*(NEEDED) *Shared library: \[\(.*\)\]$/\1/p' <<< "$dynamic")"
unexpected="$(grep -vE '^(libc\.so\.6|libm\.so\.6|libdl\.so\.2|libpthread\.so\.0|librt\.so\.1|libutil\.so\.1|libstdc\+\+\.so\.6|libgcc_s\.so\.1|libcurl\.so\.4|ld-linux-(x86-64|aarch64)\.so\.[0-9]+|libIndexStore\.so(\.[0-9.]+)?)$' <<< "$needed" || true)"
if [ -n "$unexpected" ]; then
    echo "::error::$executable needs shared libraries that not every supported distribution ships: $(tr '\n' ' ' <<< "$unexpected")" >&2
    echo "$needed" >&2
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
install -m 644 "$libxml2_license" "$stage/LICENSE-libxml2.txt"

mkdir -p "$output_dir"
tar -C "$work" --owner=0 --group=0 --numeric-owner -czf "$output_dir/$name.tar.gz" "$name"
echo "Packaged $output_dir/$name.tar.gz"
tar -tvzf "$output_dir/$name.tar.gz"
