#!/usr/bin/env bash
# Prints the SHA-256 digest of the release assets in the current directory, or checks it.
#
# The `sign` job of release.yml records the digest as a job output, and `smoke-test` and
# `publish` check the assets they download against it. An artifact can be replaced by any
# later job in the run, including one that runs the binary, but a job output cannot, so a
# match shows these are exactly the files that were signed, with no file added or removed.
# The digest covers every file's name and SHA-256, and the listing is shown in the log.
#
# Usage: release-assets-digest.sh [expected-digest]
set -euo pipefail

expected="${1:-}"
# The same file order on every runner.
export LC_ALL=C

shopt -s nullglob
files=(*)
if [ "${#files[@]}" -eq 0 ]; then
    echo "::error::No release assets in $(pwd)" >&2
    exit 1
fi

listing="$(shasum -a 256 -- "${files[@]}")"
echo "$listing" >&2
digest="$(printf '%s\n' "$listing" | shasum -a 256 | cut -d ' ' -f 1)"

if [ -z "$expected" ]; then
    echo "$digest"
elif [ "$digest" != "$expected" ]; then
    echo "::error::The release assets have digest $digest, but the sign job recorded $expected" >&2
    exit 1
else
    echo "The release assets match the digest the sign job recorded: $digest" >&2
fi
