# Lethen

A community-maintained tool to identify unused code in Swift projects.

Lethen is an independent fork of the MIT-licensed [Periphery](https://github.com/peripheryapp/periphery), originally created by Ian Leitch. It is not affiliated with or endorsed by the commercial Periphery product.

Website: **[lethen.dev](https://lethen.dev)**, whose source is [albovsky/lethen-web](https://github.com/albovsky/lethen-web). This repository is the project home.

## Status

[3.10.0](https://github.com/albovsky/lethen/releases/tag/3.10.0) is the current Lethen release and requires Swift 6.3 (Xcode 26.4) or later. Apple silicon Macs can install it with Homebrew, Linux x86_64 and aarch64 can install a release tarball, and Intel Macs build it from source. It gives every result a confidence and a reason, adds `lethen explain`, `--min-confidence`, `--configurations`, a GitHub Action, and a SwiftPM command plugin, counts uses from Objective-C, reuses verified SwiftPM builds instead of cleaning, and fixes false positives measured on a precision corpus. It runs build tools without a shell, so build arguments are no longer interpreted by one; the [release notes](docs/releases/3.10.0.md) list this and the other breaking changes. [3.8.1](https://github.com/albovsky/lethen/releases/tag/3.8.1), the first Lethen release, is the last that supports Swift 6.1 and 6.2.

Managed SwiftPM scans reuse the previous build only when Lethen can verify its index. SwiftPM does not treat `--enable-index-store` as a change that invalidates already-compiled tasks, and incremental builds do not always recompile a module's importers, so a build tree can hold a stale or partial index. Periphery 3.8.0 reads such an index without saying so: after a function that uses `AFError.isSessionInvalidatedError` was added to Alamofire, it listed neither the new function nor a change to the property, which it kept reporting. Lethen recompiled the modules the edit touched and their importers, verified the index, and reported both: the property as "referenced only from 1 unused declaration". Lethen cleans and rebuilds when there is no matching record of its last build (the first scan, other build arguments, another Swift version), when a build object another build changed belongs to no module Lethen indexed, and when the index fails verification after the build, for example a source with no unit or a recompiled module whose importers were not recompiled; `--verbose` says which. A module that another build or an edit touched is recompiled with its importers rather than cleaned, and a target the build never compiles, such as a plugin-only executable, does not block reuse. The first scan is a full rebuild, and a rescan with nothing changed rebuilds nothing. An Xcode scan likewise runs no `xcodebuild` when nothing a scan reads changed since Lethen's last completed build (see the [guide](docs/guide.md#xcode-projects-and-workspaces)). `--clean-build` always cleans. The [scan performance report](docs/validation/scan-performance.md) records the timings.

The [validation report](docs/validation/swift-6.4-xcode-27.md) records 322 passing tests, matching clean/warm/native scans, and strict self-scan results. The [audit](docs/validation/pett-audit.md) explains its 30-item sample, seven fixed false positives, 11 retained controls, and limitations. The [precision scorecard](docs/validation/precision-corpus.md) measures sampled precision on pinned open-source projects, which every analysis change re-scans. The first measurement, on 2026-09-27, was 73 %; on the current findings it is <!-- precision-figure:begin -->82.0 % over 100 sampled findings, 89.5 % over `certain` findings<!-- precision-figure:end -->, against a target of 95 %. A hosted installer is separate work.

## Install

macOS release binaries and Homebrew are Apple silicon only. See [Supported platforms](CONTRIBUTING.md#supported-platforms) for the Intel source-build support window.

On Apple silicon Macs running macOS 15 or later, install the signed and notarized binary with Homebrew:

```sh
brew install albovsky/tap/lethen
lethen version
```

Lethen loads Xcode's indexing library at launch, so Xcode must be installed as `/Applications/Xcode.app` or `/Applications/Xcode-beta.app`, or the Command Line Tools must be installed. The same binary is attached to each [release](https://github.com/albovsky/lethen/releases) as `lethen-<version>-macos-arm64.zip`, with a `SHA256SUMS` file.

[Mint](https://github.com/yonaskolb/Mint) builds it from source: `mint install albovsky/lethen@3.10.0`. To run Lethen from a package or an Xcode project, add this package with a branch or commit rule and use its `LethenPlugin` command plugin; the [guide](docs/guide.md#swift-package-plugin-and-xcode-command) shows how.

### Download the macOS zip

Download [lethen-3.10.0-macos-arm64.zip](https://github.com/albovsky/lethen/releases/download/3.10.0/lethen-3.10.0-macos-arm64.zip) and [SHA256SUMS](https://github.com/albovsky/lethen/releases/download/3.10.0/SHA256SUMS) into the same directory, then run there:

```sh
shasum -a 256 -c SHA256SUMS
ditto -x -k lethen-3.10.0-macos-arm64.zip lethen-3.10.0
mkdir -p "$HOME/.local/bin"
install -m 755 lethen-3.10.0/lethen "$HOME/.local/bin/lethen"
export PATH="$HOME/.local/bin:$PATH"
lethen version
```

Keep the PATH export in your shell profile.

### Linux

Releases from 3.9.0 include `lethen-<version>-linux-x86_64.tar.gz` and `lethen-<version>-linux-aarch64.tar.gz`. They need glibc 2.35 or later (Ubuntu 22.04, Debian 12, or newer) and a Swift 6.3 or newer toolchain, which Lethen uses to build and index your project:

```sh
version=<version>
archive="lethen-$version-linux-$(uname -m)"
curl -fsSLO "https://github.com/albovsky/lethen/releases/download/$version/$archive.tar.gz"
mkdir -p "$HOME/.local/share" "$HOME/.local/bin"
tar -xzf "$archive.tar.gz" -C "$HOME/.local/share"
ln -sf "$HOME/.local/share/$archive/bin/lethen" "$HOME/.local/bin/lethen"
export PATH="$HOME/.local/bin:$PATH"
lethen version
```

Add the `export PATH` line to your shell profile if `~/.local/bin` is not already on your `PATH`.

`bin/lethen` loads the indexing library of the `swiftc` on your `PATH`, so toolchains installed with swiftly work. Swift 6.1 and 6.2 ship an older indexing library that the binary cannot load; use a source build of 3.8.1 with them. A future Swift that moves to a newer LLVM needs a newer Lethen release.

### From source

Intel Macs build Lethen from source, and so can any Linux system with a supported toolchain. On macOS, select a full Xcode installation, for example with `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`. The local source-install baseline is Xcode 27.0 with Apple Swift 6.4 on arm64 macOS 27.

```sh
git clone --branch 3.10.0 --depth 1 https://github.com/albovsky/lethen.git
cd lethen
swift build -c release --product lethen
lethen_bin_dir="$(swift build -c release --show-bin-path)"
"$lethen_bin_dir/lethen" version
"$lethen_bin_dir/lethen" scan --help
mkdir -p "$HOME/.local/bin"
install -m 755 "$lethen_bin_dir/lethen" "$HOME/.local/bin/lethen"
export PATH="$HOME/.local/bin:$PATH"
```

Add the `export PATH` line to your shell profile to keep it in future sessions. Run `lethen scan --project-root /path/to/your/project --disable-update-check` to scan a project. Project builds may need network access to resolve dependencies. Scanning requires no account, paid plan, or commercial service.

Install prerelease tags manually. The optional update checker offers development builds newer development releases, and stable builds only stable releases.

## Verified combinations

| Build toolchain | Scanned projects / engine | Host | Evidence |
| --- | --- | --- | --- |
| Swift 6.4 / Xcode 27.0 | SwiftPM default swiftbuild and native; Xcode fixtures | arm64 macOS 27.0 | [baseline tests and scan comparisons](docs/validation/swift-6.4-xcode-27.md) |
| Swift 6.3.1 / Xcode 26.4 | SwiftPM default/native; Xcode fixtures | arm64 macOS 26.6.2 | [CI passed](https://github.com/albovsky/lethen/actions/runs/35466081905/job/105958543959) |
| Swift 6.3 and 6.4 | SwiftPM default/native | Linux x86_64, official Swift containers | `Linux` job of the [Test workflow](.github/workflows/test.yml), required on every pull request |
| 3.10.0 release binary (commit `d7dec6c`), built with Xcode 26.4 using `swift build -c release --product lethen --arch arm64` | Generated SwiftPM package (smoke scan reporting the unused function, before and after signing and notarization); Homebrew formula test | `macos-26` runner | [release run](https://github.com/albovsky/lethen/actions/runs/36950468342) |
| 3.10.0 Linux tarballs (commit `d7dec6c`), built with `swift:6.3-jammy` using `swift build -c release --product lethen --static-swift-stdlib` | Generated SwiftPM package (smoke scan reporting the unused function) | x86_64 and aarch64 with the `swift:6.3-jammy` (Swift 6.3.3, image digest `sha256:0c9411e2f70154a16f3e5660299d618a3642a445b446efe2aa637a4d01a83d54` on x86_64) and `swift:6.4-noble` (Swift 6.4) images, the `swift:6.4-resolute` image, and a swiftly Swift 6.3.3 install on x86_64 | [release run](https://github.com/albovsky/lethen/actions/runs/36950468342) |
| 3.9.0 release binary, built with Xcode 26.4 | Generated SwiftPM package (smoke scan, before and after signing and notarization); Homebrew install and `brew test` | arm64 macOS 26 runner (`macos-26-arm64` 20260907.0351.1) | [release run](https://github.com/albovsky/lethen/actions/runs/36222031977) |
| 3.9.0 Linux tarballs, built with Swift 6.3.3 in `swift:6.3-jammy` | Generated SwiftPM package (smoke scan) | x86_64 and aarch64 with the `swift:6.3-jammy` (6.3.3) and `swift:6.4-noble` (6.4) images and a swiftly Swift 6.3.3 install | [release run](https://github.com/albovsky/lethen/actions/runs/36222031977) |
| 3.8.1 release binary, built with Xcode 26.4 | Generated SwiftPM package (smoke scan) | arm64 macOS 26 runner (`macos-26-arm64` 20260907); arm64 macOS 27.0 with Xcode 27.0 via Homebrew | [release run](https://github.com/albovsky/lethen/actions/runs/36205533865) |

These checks establish specific combinations, not every Swift 6.x or macOS 15+ environment. The minimum toolchain is Swift 6.3 (Xcode 26.4): lethen supports the current Xcode major and the final release of the previous major, the Swift toolchains they ship, and the same Swift minors on Linux through the official containers. See [Supported platforms](CONTRIBUTING.md#supported-platforms) for the Intel source-build policy. Running either a Swift 6.4-built binary or the release binary on macOS 15 is unverified. Bazel's existing macOS/Linux build-and-scan jobs pass; independent Bazel distribution is not configured.

Existing `.periphery.yml` configuration files, `// periphery:ignore` comments, and the `PeripheryKit` library name remain supported. The executable is `lethen`. The inherited Bazel module and target names remain `periphery` for now; independent Bazel distribution is not yet configured.

### Bazel

Bazel mode runs the scanner from the `periphery` module in your `MODULE.bazel`. The Bazel Central Registry's `periphery` module is upstream Periphery, not lethen, so a plain `bazel_dep` scans without lethen's fixes. Override the module to build it from lethen's source, using the tag you installed:

```starlark
bazel_dep(name = "periphery", dev_dependency = True)
git_override(
    module_name = "periphery",
    remote = "https://github.com/albovsky/lethen.git",
    tag = "3.10.0",
)
use_repo(use_extension("@periphery//bazel:generated.bzl", "generated"), "periphery_generated")
```

`lethen scan --setup` prints this snippet for your installed version, and `lethen scan --bazel` warns when `MODULE.bazel` has no source override for `periphery`.

### Continuous integration

In a GitHub Actions workflow, the repository itself is the action. From 3.10.0, `uses: albovsky/lethen@<version>` installs that release's verified binary and annotates unused code on the pull request; `baseline:` limits failures to new results. On Linux the job needs a Swift 6.3 or later toolchain, for example the `swift:6.4-noble` container. The [guide](docs/guide.md#github-actions) lists the inputs and the equivalent `lethen scan` command for other CI systems.

See the [user guide](docs/guide.md) for scanning each project type, what every result means and why declarations are retained, comment commands, baselines, output formats, and continuous integration. The [historical upstream guide](docs/UPSTREAM-README.md) is kept for reference.

## Development

```sh
swift build --product lethen
swift test
```

Tests include Swift package and Xcode fixtures and may require additional platform SDKs. See [CONTRIBUTING.md](CONTRIBUTING.md). Compatibility fixes and reproducible correctness fixes are the initial focus. Maintenance is best-effort; no feature parity with future commercial Periphery releases is promised.

Report issues at [albovsky/lethen](https://github.com/albovsky/lethen/issues).

## License and attribution

[MIT](LICENSE.md). The original copyright notice is preserved unchanged. Git history, historical tags, and the upstream changelog retain the original project's attribution. Tags through 3.8.0 are upstream history, not lethen releases.
