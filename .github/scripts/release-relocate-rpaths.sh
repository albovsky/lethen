#!/usr/bin/env bash
# Points a macOS lethen binary at the libIndexStore locations users actually have.
#
# swift-index-store links `@rpath/libIndexStore.dylib` and adds the build machine's
# `xcode-select -p` toolchain as an rpath. On a CI runner that is a versioned path such
# as /Applications/Xcode_26.4.app, which no user has, so the binary would fail to launch
# anywhere else. This removes every rpath except the Swift runtime ones and adds the
# standard Xcode, Xcode beta, and Command Line Tools library directories, in that order
# of preference. Xcode installed under any other name is not found; hardened runtime
# also ignores DYLD_* overrides, so such installs need one of these paths to exist.
#
# Editing load commands invalidates the linker's signature, so the binary is re-signed
# ad hoc; the release job replaces that with the Developer ID signature.
#
# Usage: release-relocate-rpaths.sh <binary>
set -euo pipefail

binary="${1:?usage: $0 <binary>}"

keep_rpaths=(/usr/lib/swift @loader_path)
toolchain_lib=Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib
wanted_rpaths=(
    "/Applications/Xcode.app/$toolchain_lib"
    "/Applications/Xcode-beta.app/$toolchain_lib"
    /Library/Developer/CommandLineTools/usr/lib
)

rpaths() {
    otool -l "$1" | awk '$1 == "cmd" && $2 == "LC_RPATH" { getline; getline; print $2 }' | sort -u
}

while IFS= read -r rpath; do
    [ -n "$rpath" ] || continue
    keep=false
    for kept in "${keep_rpaths[@]}"; do
        [ "$rpath" = "$kept" ] && keep=true
    done
    if [ "$keep" = false ]; then
        echo "Removing rpath $rpath"
        install_name_tool -delete_rpath "$rpath" "$binary"
    fi
done < <(rpaths "$binary")

for rpath in "${wanted_rpaths[@]}"; do
    echo "Adding rpath $rpath"
    install_name_tool -add_rpath "$rpath" "$binary"
done

codesign --force --sign - "$binary"

expected="$(printf '%s\n' "${keep_rpaths[@]}" "${wanted_rpaths[@]}" | sort -u)"
actual="$(rpaths "$binary")"
if [ "$actual" != "$expected" ]; then
    echo "::error::Unexpected rpaths after relocation:" >&2
    echo "$actual" >&2
    exit 1
fi
