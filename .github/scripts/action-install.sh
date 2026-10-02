#!/usr/bin/env bash
# Installs the lethen executable for the GitHub Action (action.yml) and writes its path to
# the step's `path` output.
#
# A release version downloads that release's asset for the runner (the Apple silicon macOS
# zip or the Linux tarball for the runner's architecture) and SHA256SUMS from the release,
# verifies the checksum, and unpacks it into the runner tool cache, keyed by version and
# platform, so a later job on the same runner skips the download. `latest` resolves the
# newest stable release through the releases API first. `source` builds the action's own
# checkout with `swift build -c release` instead. An empty version means the version in the
# action's Sources/Frontend/Version.swift, which is the release version at a release tag.
#
# Release assets are only ever read here; they are published by release.yml alone.
#
# The Linux tarball loads libIndexStore from the Swift toolchain on PATH, which the scan
# also needs to build the project, so a Linux runner must have Swift 6.3 or later. The
# action does not install one.
#
# Environment: LETHEN_VERSION, GITHUB_ACTION_PATH, RUNNER_OS, RUNNER_ARCH, RUNNER_TEMP,
# RUNNER_TOOL_CACHE, GITHUB_OUTPUT, and optionally GH_TOKEN for the releases API.
set -euo pipefail

repository="albovsky/lethen"
action_path="${GITHUB_ACTION_PATH:?GITHUB_ACTION_PATH is required}"
version="${LETHEN_VERSION:-}"

fail() {
    echo "::error::$1" >&2
    exit 1
}

require_command() {
    command -v "$1" > /dev/null 2>&1 || fail "$2"
}

case "${RUNNER_OS:?RUNNER_OS is required}" in
    macOS) ;;
    Linux)
        require_command swift "Lethen on Linux needs a Swift 6.3 or later toolchain on PATH to build the project and load libIndexStore. Run the job in a swift container image or add a step that installs Swift before this action."
        ;;
    *) fail "The Lethen action supports macOS and Linux runners, not $RUNNER_OS." ;;
esac

if [ -z "$version" ]; then
    version="$(sed -n 's/^let LethenVersion = "\(.*\)"$/\1/p' "$action_path/Sources/Frontend/Version.swift")"
    [ -n "$version" ] || fail "Could not read the action's Lethen version from Sources/Frontend/Version.swift; set the version input."
    echo "Using Lethen $version, the version of this action"
fi

if [ "$version" = source ]; then
    echo "Building Lethen from $action_path"
    swift build -c release --product lethen --package-path "$action_path"
    binary="$(swift build -c release --product lethen --package-path "$action_path" --show-bin-path)/lethen"
    echo "Built lethen $("$binary" version)"
    echo "path=$binary" >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
    exit 0
fi

require_command curl "The Lethen action downloads releases with curl, which is not on PATH."

if [ "$version" = latest ]; then
    auth=()
    if [ -n "${GH_TOKEN:-}" ]; then
        auth=(-H "Authorization: Bearer $GH_TOKEN")
    fi
    # ${auth[@]+...} keeps an empty array valid under `set -u` in macOS's bash 3.2.
    release="$(curl -fsSL --retry 3 ${auth[@]+"${auth[@]}"} -H "Accept: application/vnd.github+json" \
        "https://api.github.com/repos/$repository/releases/latest")" \
        || fail "Could not look up the latest Lethen release."
    version="$(printf '%s\n' "$release" | grep -o '"tag_name": *"[^"]*"' | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/')"
    [ -n "$version" ] || fail "The latest Lethen release has no tag name."
    echo "The latest Lethen release is $version"
fi

# The version becomes part of a URL and a directory, so only release version syntax passes.
if ! printf '%s\n' "$version" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z.-]+)?$'; then
    fail "'$version' is not a Lethen version; use a release version such as 2026.10.1 (the month has no leading zero), latest, or source."
fi

case "$RUNNER_OS" in
    macOS)
        # Release binaries are Apple silicon only; see release.yml.
        [ "${RUNNER_ARCH:-}" = ARM64 ] || fail "Lethen release binaries for macOS are Apple silicon only, and this runner is ${RUNNER_ARCH:-unknown}. Use an Apple silicon runner or version: source."
        platform="macos-arm64"
        asset="lethen-$version-macos-arm64.zip"
        executable="lethen"
        ;;
    Linux)
        case "${RUNNER_ARCH:-}" in
            X64) arch=x86_64 ;;
            ARM64) arch=aarch64 ;;
            *) fail "Lethen release binaries for Linux are x86_64 and aarch64 only, and this runner is ${RUNNER_ARCH:-unknown}." ;;
        esac
        platform="linux-$arch"
        asset="lethen-$version-linux-$arch.tar.gz"
        executable="lethen-$version-linux-$arch/bin/lethen"
        ;;
esac

cache="${RUNNER_TOOL_CACHE:-${RUNNER_TEMP:?RUNNER_TEMP is required}}/lethen/$version/$platform"
binary="$cache/$executable"

# The marker is written last, so an interrupted unpack is never mistaken for a complete one.
if [ -f "$cache.complete" ] && [ -x "$binary" ]; then
    echo "Using Lethen $version from the tool cache at $cache"
else
    download="$(mktemp -d "${RUNNER_TEMP:-/tmp}/lethen-download.XXXXXX")"
    trap 'rm -rf "$download"' EXIT
    base="https://github.com/$repository/releases/download/$version"

    echo "Downloading $asset"
    curl -fsSL --retry 3 -o "$download/$asset" "$base/$asset" \
        || fail "Could not download $asset from the Lethen $version release. Check that the version exists and has a $platform asset."
    curl -fsSL --retry 3 -o "$download/SHA256SUMS" "$base/SHA256SUMS" \
        || fail "Could not download SHA256SUMS from the Lethen $version release."

    expected="$(awk -v name="$asset" '$2 == name || $2 == "*" name { print $1 }' "$download/SHA256SUMS")"
    [ -n "$expected" ] || fail "SHA256SUMS of the Lethen $version release has no entry for $asset."
    if command -v sha256sum > /dev/null 2>&1; then
        actual="$(sha256sum "$download/$asset" | awk '{ print $1 }')"
    else
        actual="$(shasum -a 256 "$download/$asset" | awk '{ print $1 }')"
    fi
    [ "$actual" = "$expected" ] || fail "$asset does not match its SHA256SUMS entry (expected $expected, got $actual)."
    echo "Verified $asset against SHA256SUMS"

    rm -rf "$cache" "$cache.complete"
    mkdir -p "$cache"
    case "$asset" in
        *.zip) unzip -q "$download/$asset" -d "$cache" ;;
        *.tar.gz) tar -xzf "$download/$asset" -C "$cache" ;;
    esac
    [ -x "$binary" ] || fail "$asset does not contain $executable."
    touch "$cache.complete"
    echo "Installed Lethen $version into $cache"
fi

reported="$("$binary" version)" \
    || fail "The installed lethen executable does not run; the output above names what is missing. Linux release binaries are tested on the swift:6.3-jammy and swift:6.4-noble images, and releases after 3.9.0 also on swift:6.4-resolute."
[ "$reported" = "$version" ] || fail "The installed lethen reports version $reported, expected $version."
echo "path=$binary" >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
