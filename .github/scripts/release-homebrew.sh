#!/usr/bin/env bash
# Tests and publishes the lethen formula for the Homebrew tap.
#
# The formula installs the notarized Apple silicon binary from the GitHub release. Its two
# modes run in different jobs of release.yml, so the binary never runs where a token is:
#
# test     In the unprivileged smoke-test job, writes the formula for the local signed
#          zip (a file:// URL and its SHA-256) into a throwaway local tap, runs
#          `brew install` and `brew test` from it, and removes both again. It refuses to
#          run with a token in the environment.
# publish  In the publish job, writes the same formula with the release URL and pushes it
#          to the tap. The tap only moves forward: when it already has this version or a
#          newer one (for example when an older tag is backfilled), it is left alone.
#          Before pushing, it downloads the published asset and checks that it is the zip
#          that was tested. It never runs brew or the binary.
#
# Inputs (environment): GH_REPO (owner/name of this repository). For publish, also
# HOMEBREW_TAP (owner/homebrew-name), HOMEBREW_TAP_TOKEN with contents write access to the
# tap, and optionally HOMEBREW_TAP_REMOTE, a git URL that replaces the tap's GitHub remote
# for both clone and push, for testing against a local repository.
#
# Usage: release-homebrew.sh test|publish <tag> <macos-zip>
set -euo pipefail

usage="usage: $0 test|publish <tag> <macos-zip>"
mode="${1:?$usage}"
tag="${2:?$usage}"
zip="${3:?$usage}"
case "$mode" in
    test | publish) ;;
    *)
        echo "$usage" >&2
        exit 1
        ;;
esac
repo="${GH_REPO:?GH_REPO is required}"
sha256="$(shasum -a 256 "$zip" | cut -d ' ' -f 1)"

# Writes the formula for the zip at the URL $2 to the file $1.
write_formula() {
    local formula="$1" url="$2"
    mkdir -p "$(dirname "$formula")"
    cat > "$formula" <<EOF
class Lethen < Formula
  desc "Identify unused code in Swift projects"
  homepage "https://github.com/$repo"
  url "$url"
  version "$tag"
  sha256 "$sha256"
  license "MIT"

  depends_on arch: :arm64
  depends_on macos: :sequoia

  def install
    bin.install "lethen"
  end

  test do
    assert_equal version.to_s, shell_output("#{bin}/lethen version").strip
  end
end
EOF
}

# Commits the formula in the tap checkout at $1.
commit_formula() {
    git -C "$1" add Formula/lethen.rb
    git -C "$1" -c user.name="github-actions[bot]" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
        commit --quiet -m "lethen $tag"
}

work="$(mktemp -d)"

case "$mode" in
    test)
        for name in HOMEBREW_TAP_TOKEN GH_TOKEN GITHUB_TOKEN; do
            if [ -n "${!name:-}" ]; then
                echo "::error::$name is set; the formula test runs the binary and must run without tokens" >&2
                exit 1
            fi
        done
        # A tap name of its own, so a developer's real tap is never replaced or removed.
        tap_name="lethen-release/smoke"
        cleanup() {
            brew uninstall --formula "$tap_name/lethen" > /dev/null 2>&1 || true
            brew untap "$tap_name" > /dev/null 2>&1 || true
            rm -rf "$work"
        }
        trap cleanup EXIT

        zip_path="$(cd "$(dirname "$zip")" && pwd -P)/$(basename "$zip")"
        git init --quiet "$work/tap"
        write_formula "$work/tap/Formula/lethen.rb" "file://$zip_path"
        commit_formula "$work/tap"

        export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ANALYTICS=1
        brew tap "$tap_name" "$work/tap"
        brew install --formula "$tap_name/lethen"
        brew test "$tap_name/lethen"
        echo "Installed and tested the lethen $tag formula from $zip"
        ;;
    publish)
        trap 'rm -rf "$work"' EXIT
        tap_repo="${HOMEBREW_TAP:?HOMEBREW_TAP is required}"
        tap_owner="${tap_repo%%/*}"
        tap_name="$tap_owner/${tap_repo#*/homebrew-}"
        if [ -n "${HOMEBREW_TAP_REMOTE:-}" ]; then
            clone_url="$HOMEBREW_TAP_REMOTE"
            push_url="$HOMEBREW_TAP_REMOTE"
        else
            clone_url="https://github.com/$tap_repo.git"
            push_url="https://x-access-token:${HOMEBREW_TAP_TOKEN:?HOMEBREW_TAP_TOKEN is required}@github.com/$tap_repo.git"
        fi
        url="https://github.com/$repo/releases/download/$tag/$(basename "$zip")"

        git clone --quiet --depth 1 "$clone_url" "$work/tap"
        formula="$work/tap/Formula/lethen.rb"
        if [ -f "$formula" ]; then
            current="$(sed -n 's/^  version "\(.*\)"$/\1/p' "$formula")"
            if [ -n "$current" ] && [ "$(printf '%s\n' "$current" "$tag" | sort -V | tail -n 1)" = "$current" ]; then
                echo "The tap already has lethen $current; not changing it for $tag"
                exit 0
            fi
        fi

        # Downloaded only to compare checksums with the zip the smoke-test job tested;
        # never unpacked or run.
        curl --fail --silent --show-error --location --retry 5 --output "$work/published.zip" "$url"
        published_sha256="$(shasum -a 256 "$work/published.zip" | cut -d ' ' -f 1)"
        if [ "$published_sha256" != "$sha256" ]; then
            echo "::error::Published asset $url has SHA-256 $published_sha256, expected $sha256" >&2
            exit 1
        fi

        write_formula "$formula" "$url"
        commit_formula "$work/tap"
        git -C "$work/tap" push --quiet "$push_url" HEAD:main
        echo "Pushed $tap_name/lethen $tag"
        ;;
esac
