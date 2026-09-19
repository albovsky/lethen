# lethen

A community-maintained tool to identify unused code in Swift projects.

Lethen is an independent fork of the MIT-licensed [Periphery](https://github.com/peripheryapp/periphery), originally created by Ian Leitch. It is not affiliated with or endorsed by the commercial Periphery product.

Intended website: **lethen.sh**. This repository is the project home while the website is being prepared.

## Status

Initial development fork, based on Periphery 3.8.0. No lethen binary release, Homebrew formula, or hosted installer is available yet. Compatibility is being established; inherited platform support is not a new certification. See the [initial validation report](docs/VALIDATION.md) for known Xcode 27 / Swift 6.4 blockers.

## Build and run

With a Swift toolchain installed (on macOS, select a full Xcode installation):

```sh
git clone https://github.com/albovsky/lethen.git
cd lethen
swift build -c release --product lethen
.build/release/lethen version
.build/release/lethen scan --help
```

Run `.build/release/lethen scan --project-root /path/to/your/project --disable-update-check` to scan a project without the optional GitHub update check. Project builds may still need network access to resolve dependencies. Scanning requires no account, paid plan, or commercial service.

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
