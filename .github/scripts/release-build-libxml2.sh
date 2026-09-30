#!/usr/bin/env bash
# Builds a static libxml2 for the Linux release executable.
#
# Lethen parses XIBs, storyboards, Info.plists, and Core Data models with AEXML, which uses
# Foundation's XMLParser from FoundationXML, and FoundationXML links libxml2. Linked
# dynamically, the executable needs the build image's libxml2.so.2, and Ubuntu 26.04 ships
# only libxml2.so.16, so the executable would not start there. This builds libxml2 from
# the build image's own Ubuntu source package, with Ubuntu's security patches and the
# version FoundationXML was compiled against, as a static library without ICU, zlib, or
# liblzma, so it needs nothing beyond glibc. Linking with -L<prefix>/lib makes
# FoundationXML's -lxml2 resolve to it, since that directory holds no shared libxml2.
#
# It installs <prefix>/lib/libxml2.a and <prefix>/COPYING, libxml2's license, which the
# tarball must carry. Run it as root in the release build container.
#
# Usage: release-build-libxml2.sh <prefix>
set -euo pipefail

prefix="${1:?usage: $0 <prefix>}"
mkdir -p "$prefix/lib"
prefix="$(cd "$prefix" && pwd)"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# apt verifies the source package against the archive's signed index.
sed -n 's/^deb /deb-src /p' /etc/apt/sources.list > /etc/apt/sources.list.d/lethen-deb-src.list
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends dpkg-dev > /dev/null

cd "$work"
apt-get source -qq libxml2 2>&1 | { grep -v '^dpkg-source: info: applying ' || true; }
cd libxml2-*/

CC=clang ./configure --quiet --disable-shared --enable-static --with-pic \
    --without-icu --without-zlib --without-lzma --without-python --without-http --without-ftp
# Only the library: the documentation's makefiles need automake after Ubuntu's patches.
make -s -j"$(nproc)" libxml2.la
cp .libs/libxml2.a "$prefix/lib/libxml2.a"
cp Copyright "$prefix/COPYING"

undefined="$(nm -u "$prefix/lib/libxml2.a" | awk '$1 == "U" { print $2 }' | sort -u)"
if grep -qE '^(u_|ucnv_|lzma_|gz|inflate|deflate)' <<< "$undefined"; then
    echo "::error::libxml2.a still needs ICU, zlib, or liblzma" >&2
    exit 1
fi
echo "Built $prefix/lib/libxml2.a from $(basename "$PWD")"
