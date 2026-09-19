# lethen

A community-maintained tool to identify unused code in Swift projects.

Lethen is an independent fork of the MIT-licensed [Periphery](https://github.com/peripheryapp/periphery), originally created by Ian Leitch. It is not affiliated with or endorsed by the commercial Periphery product.

Intended website: **lethen.sh**. This repository is the project home while the website is being prepared.

## Status

[3.8.1-dev.1](https://github.com/albovsky/lethen/releases/tag/3.8.1-dev.1) is the first lethen development prerelease, distributed from source. It fixes default SwiftPM index discovery and fixture setup on Swift 6.4 / Xcode 27, plus two analysis defects reproduced during a private-project audit.

The [validation report](docs/validation/swift-6.4-xcode-27.md) records 321 passing tests, matching clean/warm/native scans, and strict self-scan results. The [audit](docs/validation/pett-audit.md) explains its 30-item sample, seven fixed false positives, 11 retained controls, and limitations. Signed binaries, Homebrew, and a hosted installer are separate work.

## Install from source

On macOS, select a full Xcode installation, for example with `sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`. The local source-install baseline is Xcode 27.0 with Apple Swift 6.4 on arm64 macOS 27.

```sh
git clone --branch 3.8.1-dev.1 --depth 1 https://github.com/albovsky/lethen.git
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

Install prerelease tags manually: the optional update checker uses GitHub's stable `/releases/latest` endpoint and does not discover prereleases.

## Verified combinations

| Build toolchain | Scanned projects / engine | Host | Evidence |
| --- | --- | --- | --- |
| Swift 6.4 / Xcode 27.0 | SwiftPM default swiftbuild and native; Xcode fixtures | arm64 macOS 27.0 | [321 tests and scan comparisons](https://github.com/albovsky/lethen/actions/runs/35463547167/job/105951571722) |
| Swift 6.1.2 / Xcode 16.4 | SwiftPM default/native; Xcode fixtures | arm64 macOS 15.7.9 | [CI passed](https://github.com/albovsky/lethen/actions/runs/35463547167/job/105951571789) |
| Swift 6.2.4 / Xcode 26.3.0 | SwiftPM default/native; Xcode fixtures | arm64 macOS 26.6.2 | [CI passed](https://github.com/albovsky/lethen/actions/runs/35463547167/job/105951571743) |
| Swift 6.3.1 / Xcode 26.4 | SwiftPM default/native; Xcode fixtures | arm64 macOS 26.6.2 | [CI passed](https://github.com/albovsky/lethen/actions/runs/35463547167/job/105951571806) |
| Swift 6.1.3 / 6.2.4 / 6.3.3 | SwiftPM default/native | Linux x86_64, official Swift containers | [CI details](docs/validation/swift-6.4-xcode-27.md#verified-combinations) |

These checks establish specific combinations, not every Swift 6.x or macOS 15+ environment. Intel macOS and running a Swift 6.4-built binary on macOS 15 are unverified. Bazel's existing macOS/Linux build-and-scan jobs pass; independent Bazel distribution is not configured.

Existing `.periphery.yml` configuration files, `// periphery:ignore` comments, and the `PeripheryKit` library name remain supported. The executable is `lethen`. The inherited Bazel module and target names remain `periphery` for now; independent Bazel distribution is not yet configured.

See the [historical upstream guide](docs/UPSTREAM-README.md) for analysis options and concepts. Its installation, release, sponsorship, and support links describe upstream Periphery, not lethen; substitute `lethen` for CLI invocations.

## Development

```sh
swift build --product lethen
swift test
```

Tests include Swift package and Xcode fixtures and may require additional platform SDKs. See [CONTRIBUTING.md](CONTRIBUTING.md). Compatibility fixes and reproducible correctness fixes are the initial focus. Maintenance is best-effort; no feature parity with future commercial Periphery releases is promised.

Report issues at [albovsky/lethen](https://github.com/albovsky/lethen/issues).

## License and attribution

[MIT](LICENSE.md). The original copyright notice is preserved unchanged. Git history, historical tags, and the upstream changelog retain the original project's attribution. Tags through 3.8.0 are upstream history, not lethen releases.
