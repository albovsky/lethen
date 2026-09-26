#!/usr/bin/env bash
# Updates the lethen formula in the Homebrew tap to a published release.
#
# The formula installs the notarized Apple silicon binary from the GitHub release. The
# tap only moves forward: when it already has this version or a newer one (for example
# when an older tag is backfilled), it is left alone. Before the tap is pushed, this
# checks that the published asset is the one that was built, then taps the updated local
# clone and runs `brew install` and `brew test` against it, so users never receive a
# formula that does not install.
#
# Inputs (environment): HOMEBREW_TAP_TOKEN with contents write access to the tap,
# HOMEBREW_TAP (owner/homebrew-name), GH_REPO (owner/name of this repository), and
# optionally HOMEBREW_TAP_REMOTE, a git URL that replaces the tap's GitHub remote for
# both clone and push, for testing against a local repository.
#
# Usage: release-homebrew.sh <tag> <macos-zip>
set -euo pipefail

tag="${1:?usage: $0 <tag> <macos-zip>}"
zip="${2:?usage: $0 <tag> <macos-zip>}"
tap_repo="${HOMEBREW_TAP:?HOMEBREW_TAP is required}"
repo="${GH_REPO:?GH_REPO is required}"

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
sha256="$(shasum -a 256 "$zip" | cut -d ' ' -f 1)"

work="$(mktemp -d)"
cleanup() {
    brew uninstall --formula "$tap_name/lethen" > /dev/null 2>&1 || true
    brew untap "$tap_name" > /dev/null 2>&1 || true
    rm -rf "$work"
}
trap cleanup EXIT

git clone --quiet --depth 1 "$clone_url" "$work/tap"
formula="$work/tap/Formula/lethen.rb"
if [ -f "$formula" ]; then
    current="$(sed -n 's/^  version "\(.*\)"$/\1/p' "$formula")"
    if [ -n "$current" ] && [ "$(printf '%s\n' "$current" "$tag" | sort -V | tail -n 1)" = "$current" ]; then
        echo "The tap already has lethen $current; not changing it for $tag"
        exit 0
    fi
fi

curl --fail --silent --show-error --location --retry 5 --output "$work/published.zip" "$url"
published_sha256="$(shasum -a 256 "$work/published.zip" | cut -d ' ' -f 1)"
if [ "$published_sha256" != "$sha256" ]; then
    echo "::error::Published asset $url has SHA-256 $published_sha256, expected $sha256" >&2
    exit 1
fi

mkdir -p "$work/tap/Formula"
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

cd "$work/tap"
git add Formula/lethen.rb
git -c user.name="github-actions[bot]" -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
    commit --quiet -m "lethen $tag"

export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_ANALYTICS=1
brew tap "$tap_name" "$work/tap"
brew install --formula "$tap_name/lethen"
brew test "$tap_name/lethen"

git push --quiet "$push_url" HEAD:main
echo "Pushed $tap_name/lethen $tag"
