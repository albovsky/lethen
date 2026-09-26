#!/usr/bin/env bash
# Publishes the GitHub release for a tag with its binary assets.
#
# A new release is created as a draft, given its assets, and only then published, so
# nobody can download a release with missing files. The notes come from
# docs/releases/<tag>.md when that file exists, otherwise GitHub generates them. A tag
# that already has a release (a backfill, or a rerun after a later step failed) keeps its
# notes and state, and a draft is published. Published assets are never replaced: the
# Homebrew formula pins their checksums, so an asset that is already there must be
# byte-identical to the local file, and only missing assets are uploaded.
#
# Inputs (environment): GH_TOKEN with `contents: write`, GH_REPO (owner/name).
#
# Usage: release-publish.sh <tag> <prerelease: true|false> <notes-file> <asset>...
set -euo pipefail

tag="${1:?usage: $0 <tag> <prerelease> <notes-file> <asset>...}"
prerelease="${2:?usage: $0 <tag> <prerelease> <notes-file> <asset>...}"
notes_file="${3:?usage: $0 <tag> <prerelease> <notes-file> <asset>...}"
shift 3
assets=("$@")
[ "${#assets[@]}" -gt 0 ] || {
    echo "::error::No assets to publish" >&2
    exit 1
}

if [ "$prerelease" = true ]; then
    state_args=(--prerelease --latest=false)
else
    state_args=(--latest)
fi

if is_draft="$(gh release view "$tag" --json isDraft --jq .isDraft 2> /dev/null)"; then
    echo "Release $tag exists; uploading only missing assets"
    existing="$(gh release view "$tag" --json assets --jq '.assets[].name')"
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    missing=()
    for asset in "${assets[@]}"; do
        name="$(basename "$asset")"
        if grep -qxF "$name" <<< "$existing"; then
            gh release download "$tag" --pattern "$name" --dir "$work"
            if ! cmp -s "$asset" "$work/$name"; then
                echo "::error::$name is already published for $tag with different contents; published assets are never replaced" >&2
                exit 1
            fi
            echo "$name is already published and identical"
        else
            missing+=("$asset")
        fi
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        gh release upload "$tag" "${missing[@]}"
    fi
    if [ "$is_draft" = true ]; then
        gh release edit "$tag" --draft=false "${state_args[@]}"
    fi
else
    if [ -f "$notes_file" ]; then
        notes_args=(--notes-file "$notes_file")
    else
        notes_args=(--generate-notes)
    fi
    gh release create "$tag" --verify-tag --draft --title "lethen $tag" "${notes_args[@]}" "${state_args[@]}"
    gh release upload "$tag" "${assets[@]}"
    gh release edit "$tag" --draft=false "${state_args[@]}"
fi

gh release view "$tag" --json url,isDraft,isPrerelease,assets \
    --jq '"\(.url) draft=\(.isDraft) prerelease=\(.isPrerelease) assets=\([.assets[].name] | join(", "))"'
