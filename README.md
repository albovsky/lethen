# Lethen

A community-maintained tool to identify unused code in Swift projects.

Lethen is an independent fork of the MIT-licensed [Periphery](https://github.com/peripheryapp/periphery), originally created by Ian Leitch. It is not affiliated with or endorsed by the commercial Periphery product.

Intended website: **lethen.sh**. This repository is the project home while the website is being prepared.

## Status

[3.8.1](https://github.com/albovsky/lethen/releases/tag/3.8.1) is the first Lethen release. Apple silicon Macs can install it with Homebrew; Intel Macs and Linux build it from source. It makes scanning reliable on Swift 6.4 / Xcode 27, fixes analysis defects reproduced during a private-project audit, and turns the remaining crash paths into reported errors. It is the last release that supports Swift 6.1 and 6.2; 3.9.0 requires Swift 6.3 (Xcode 26.4).

Managed SwiftPM scans clean and rebuild existing products to guarantee a fresh index. This is deliberate and it has a real cost: **a managed SwiftPM scan is always a full rebuild, never an incremental one.** SwiftPM does not treat `--enable-index-store` as a change that invalidates already-compiled tasks, so a build tree produced by a plain `swift build` yields a stale or partial index and silently wrong results. Cleaning is the only way we can currently rule that out.

To keep incremental builds, build the index yourself and scan it with `--skip-build --index-store-path <path>`. Use `--skip-build` only with an index you know is current.

The [validation report](docs/validation/swift-6.4-xcode-27.md) records 322 passing tests, matching clean/warm/native scans, and strict self-scan results. The [audit](docs/validation/pett-audit.md) explains its 30-item sample, seven fixed false positives, 11 retained controls, and limitations. A hosted installer is separate work.

## Install

On Apple silicon Macs running macOS 15 or later, install the signed and notarized binary with Homebrew:

```sh
brew install albovsky/tap/lethen
lethen version
```

Lethen loads Xcode's indexing library at launch, so Xcode must be installed as `/Applications/Xcode.app` or `/Applications/Xcode-beta.app`, or the Command Line Tools must be installed. The same binary is attached to each [release](https://github.com/albovsky/lethen/releases) as `lethen-<version>-macos-arm64.zip`, with a `SHA256SUMS` file.

### Linux

Releases after 3.8.1 include `lethen-<version>-linux-x86_64.tar.gz` and `lethen-<version>-linux-aarch64.tar.gz`. They need glibc 2.35 or later (Ubuntu 22.04, Debian 12, or newer) and a Swift 6.3 or newer toolchain, which Lethen uses to build and index your project:

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
git clone --branch 3.8.1 --depth 1 https://github.com/albovsky/lethen.git
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
| 3.8.1 release binary, built with Xcode 26.4 | Generated SwiftPM package (smoke scan) | arm64 macOS 26 runner (`macos-26-arm64` 20260907); arm64 macOS 27.0 with Xcode 27.0 via Homebrew | [release run](https://github.com/albovsky/lethen/actions/runs/36205533865) |

These checks establish specific combinations, not every Swift 6.x or macOS 15+ environment. Intel macOS, running a Swift 6.4-built binary on macOS 15, and running the release binary on macOS 15 are unverified. Bazel's existing macOS/Linux build-and-scan jobs pass; independent Bazel distribution is not configured. The minimum toolchain is Swift 6.3 (Xcode 26.4): lethen supports the current Xcode major and the final release of the previous major, the Swift toolchains they ship, and the same Swift minors on Linux through the official containers. Intel macOS and running a Swift 6.4-built binary on macOS 15 are unverified. Bazel's existing macOS/Linux build-and-scan jobs pass; independent Bazel distribution is not configured.

Existing `.periphery.yml` configuration files, `// periphery:ignore` comments, and the `PeripheryKit` library name remain supported. The executable is `lethen`. The inherited Bazel module and target names remain `periphery` for now; independent Bazel distribution is not yet configured.

### Bazel

Bazel mode runs the scanner from the `periphery` module in your `MODULE.bazel`. The Bazel Central Registry's `periphery` module is upstream Periphery, not lethen, so a plain `bazel_dep` scans without lethen's fixes. Override the module to build it from lethen's source, using the tag you installed:

```starlark
bazel_dep(name = "periphery", dev_dependency = True)
git_override(
    module_name = "periphery",
    remote = "https://github.com/albovsky/lethen.git",
    tag = "3.8.1",
)
use_repo(use_extension("@periphery//bazel:generated.bzl", "generated"), "periphery_generated")
```

`lethen scan --setup` prints this snippet for your installed version, and `lethen scan --bazel` warns when `MODULE.bazel` has no source override for `periphery`.

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
