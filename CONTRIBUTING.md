# Contributing to lethen

Lethen continues the MIT-licensed Periphery codebase. Contributions are accepted under the repository's MIT license; retain existing copyright and license notices.

Start with `swift build --product lethen` and `swift test`. Xcode integration tests need full Xcode and the fixture SDKs. Include your OS, Swift and Xcode versions in bug reports, together with the command, relevant configuration, and a minimal reproducible project. Remove secrets and proprietary code before sharing fixtures.

Analysis changes should include a regression test demonstrating both declarations that must be reported and declarations that must be retained where applicable. Discuss major features and dependency or distribution changes in an issue first. Prefer small, reviewable patches; generated or AI-assisted changes need the same evidence as any other contribution.

Initial scope is compatibility and correctness maintenance. Support is best-effort. Existing Periphery configuration and comment syntax remain compatible. Do not mass-rename internal modules or fixtures as part of branding changes.

Run `bash .github/scripts/verify-swift-6.4.sh` for the required Xcode 27 baseline. It verifies the toolchain, runs the full suite, compares clean/warm/native fixture findings, and performs a strict self-scan. Evidence is written to `.validation/`. The matching GitHub check is required on `master`; test setup errors must fail tests, and new analysis behavior needs both reported and retained controls. Use `swift build --show-bin-path` to locate executables rather than assuming a build-engine layout.

Development releases are source-only and manually gated. Set the version, validate a clean candidate checkout and its exact CI commit, create an immutable tag and draft prerelease, then verify a fresh installation from that public tag before publishing the ready draft. Record installation and CI evidence in the release notes. Use the [3.8.1-dev.1 notes](docs/releases/3.8.1-dev.1.md) as the initial checklist. Prereleases are installed manually; the stable update endpoint does not discover them.

The inherited binary signing/publishing script remains disabled. Do not use upstream credentials or publish into upstream registries. Tags through 3.8.0 are upstream history, not lethen releases.
