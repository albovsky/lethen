#!/bin/sh
# Starts lethen with the libIndexStore of the active Swift toolchain.
#
# This file is installed as bin/lethen in the Linux release tarball; the executable is
# libexec/lethen/lethen. Lethen reads the index your project's build writes through the
# toolchain's libIndexStore.so, which is only on the default library path when the
# toolchain lives in /usr, as in the official Swift images. For swiftly and other
# installs, this asks the `swiftc` on PATH, the same one Lethen builds your project
# with, where its runtime lives, and searches that toolchain's lib directory first.
set -e

here="$(dirname "$(readlink -f "$0")")"
resource="$(swiftc -print-target-info 2> /dev/null | sed -n 's/^ *"runtimeResourcePath": "\(.*\)",*$/\1/p')" || true
if [ -n "$resource" ]; then
    LD_LIBRARY_PATH="$(dirname "$resource")${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
    export LD_LIBRARY_PATH
fi
exec "$here/../libexec/lethen/lethen" "$@"
