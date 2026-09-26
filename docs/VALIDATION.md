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

These paths were not changed during the fork setup. They need reproducible compatibility fixes before claiming Xcode 27 support. Compilation alone does not establish analysis correctness. Linux and Bazel are now covered by the CI matrix below; binary packaging, signing, and notarization are still unvalidated for lethen.

## Distribution

The development prerelease 3.8.1-dev.1 and the stable release 3.8.1 (see `releases/`) were distributed from source. Signed, notarized macOS binaries and the `albovsky/homebrew-tap` formula are published by the `Release` workflow described in `CONTRIBUTING.md`; they are unvalidated until its first run. The inherited publisher and the original maintainer's signing/notarization script remain disabled. SwiftPM and Docker executable paths use lethen; legacy configuration, library, cache, and Bazel names remain for compatibility. The commercial plan suggestion client is removed. Optional update checking points to `albovsky/lethen`; until a release exists, explicit `check-update` cannot find a latest release.

The intended domain is lethen.sh; repository setup does not register the domain or deploy a website.

## Reliable scanning follow-up

The local Swift 6.4/Xcode 27 implementation now passes 323 tests across all four targets with no failures or skips: 247 in PeripheryTests, 41 in AccessibilityTests, 22 in XcodeTests, and 13 in SPMTests. Clean/warm/default/native fixture findings match, and the strict clean self-scan passes after removal of an orphaned frontend line-count field. See [the detailed baseline](validation/swift-6.4-xcode-27.md) for the actual index-layout discovery, commands, coverage and compatibility limits. The [Pett audit](validation/pett-audit.md) reviewed 30 findings, fixed seven sampled false positives, verified 11 retained controls, and passed 60 mutation tests. The dedicated hosted baseline is green and required on master. The stable macOS/Linux matrix and all Bazel jobs build, scan, and test cleanly, including the Linux update check teardown check recorded below. The versioned source-install gate and final release evidence are recorded in the release notes.

## Linux update check teardown

The scan starts a GitHub update request up front, and tearing down its `URLSession`
aborted the process on Linux after an otherwise successful scan, with correct output
already written.

`ScanCommand` now waits for the request to settle before reading it, and `deinit` no longer
invalidates the session on Linux at all. The first of those changes removed the original
SIGILL but only narrowed the window: CI caught an intermittent SIGSEGV on Swift 6.1 with the
request already settled, one run in five (run 35492455881). Swift 6.2, 6.3, and
main-snapshot passed. The crash cannot be reproduced on macOS, so Linux CI is the evidence.

`.github/scripts/verify-update-check-teardown.sh` runs 15 scans with update checks enabled
and fails the Linux job if any process dies. With the Linux teardown removed, every Linux
job passed all 15 iterations (run 35493330055, Swift 6.1, 6.2, 6.3, and main-snapshot). At
the observed one-in-five failure rate, an unfixed build would pass 15 runs by luck about 3%
of the time, so each further green Linux run strengthens this evidence; a single failure
reopens it.

CI scan gates pass `--disable-update-check`, so this never affected scan validation.
