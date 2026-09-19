# Initial fork validation — 2026-09-19

For the current development release, see [3.8.1-dev.1](releases/3.8.1-dev.1.md) and the [verified combinations](validation/swift-6.4-xcode-27.md#verified-combinations). The initial observations below are historical.

Upstream base: `56a0eb6` (README update following the 3.8.0 release at `a2db299`). Original history, tags, and MIT license are preserved.

Environment: Apple Silicon, macOS 27, Xcode 27.0 (27A266a), Apple Swift 6.4.

- Unmodified upstream `swift build --product periphery`: passed.
- Fork `swift build --product lethen`: passed.
- `lethen version`: prints `3.8.1-dev`.
- `lethen --help` and `lethen scan --help`: passed.
- Focused SwiftVersionParserTest and StringVersionTest: 2 tests passed.
- Fixture scan with `--disable-update-check --format json -- --build-system native`: completed and returned valid JSON (404 findings). This verifies execution, not every finding's correctness.
- Full `swift test`: compiled, but test fixture setup crashed. This is not a passing test suite.

## Initial compatibility blockers

The Swift package fixture tests expect `.build/debug/index/store`, which was absent after the default Swift 6.4 build. The setup code force-unwraps this error and terminates the test process with signal 5.

The SwiftUI Xcode fixture targets iOS 14.5. Xcode 27 rejects that deployment target because its supported range starts at iOS 15.0, producing xcodebuild exit status 65 and another force-unwrapped setup error.

These paths were not changed during the fork setup. They need reproducible compatibility fixes before claiming Xcode 27 support. Compilation alone does not establish analysis correctness. Linux, Bazel, binary packaging, signing, and notarization have not been validated for lethen.

## Distribution

No lethen release has been published. The inherited publisher and original maintainer's signing/notarization script are disabled. SwiftPM and Docker executable paths use lethen; legacy configuration, library, cache, and Bazel names remain for compatibility. The commercial plan suggestion client is removed. Optional update checking points to `albovsky/lethen`; until a release exists, explicit `check-update` cannot find a latest release.

The intended domain is lethen.sh; repository setup does not register the domain or deploy a website.

## Reliable scanning follow-up

The local Swift 6.4/Xcode 27 implementation now passes 322 tests across all four targets with no failures or skips. Clean/warm/default/native fixture findings match, and the strict clean self-scan passes after removal of an orphaned frontend line-count field. See [the detailed baseline](validation/swift-6.4-xcode-27.md) for the actual index-layout discovery, commands, coverage and compatibility limits. The [Pett audit](validation/pett-audit.md) reviewed 30 findings, fixed seven sampled false positives, verified 11 retained controls, and passed 60 mutation tests. The dedicated hosted baseline is green and required on master. The stable macOS/Linux matrix and all Bazel jobs pass. The versioned source-install gate and final release evidence are recorded in the release notes.
