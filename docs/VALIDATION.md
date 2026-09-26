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

These paths were not changed during the fork setup. They need reproducible compatibility fixes before claiming Xcode 27 support. Compilation alone does not establish analysis correctness. Linux and Bazel are now covered by the CI matrix below. Apple silicon binary packaging, signing, and notarization were validated by the 3.8.1 backfill (see Distribution); Intel binaries are not built. Linux tarballs are built and smoke-tested by `.github/workflows/release-linux.yml`; before it existed, three experiment runs on a throwaway branch established their compatibility: a Swift 6.3-built static-stdlib executable ran the smoke scan with the Swift 6.3, 6.4, and 6.5-dev (nightly-main) images on x86_64 and aarch64 and, through the launcher, with a swiftly Swift 6.3 install on Ubuntu 24.04; Swift 6.1 and 6.2 fail with `version 'LLVM_21.0' not found`, which neither renaming the needed library nor clearing symbol versions fixes ([36206536725](https://github.com/albovsky/lethen/actions/runs/36206536725), [36207136912](https://github.com/albovsky/lethen/actions/runs/36207136912), [36207675769](https://github.com/albovsky/lethen/actions/runs/36207675769)).

## Distribution

The development prerelease 3.8.1-dev.1 and the stable release 3.8.1 (see `releases/`) were first distributed from source. The `Release` workflow described in `CONTRIBUTING.md` publishes signed, notarized Apple silicon binaries and the `albovsky/homebrew-tap` formula. Its first run, [36205533865](https://github.com/albovsky/lethen/actions/runs/36205533865), backfilled 3.8.1 from master at 4bdc60b: built with Xcode 26.4 on the `macos-26-arm64` image, signed by Developer ID team 6YWGVNTHSS with hardened runtime, notarized (submission 307ebc0a-25ae-46d7-b3ad-13d1bacc7d93, Accepted), accepted by Gatekeeper as `Notarized Developer ID`, smoke-tested before and after signing, and installed and tested through Homebrew before the formula was pushed. The published zip was then downloaded on arm64 macOS 27.0 with Xcode 27.0: its checksum matched `SHA256SUMS` and the formula, the quarantined binary ran, and `brew install albovsky/tap/lethen` passed the same smoke scan. The inherited publisher and the original maintainer's signing/notarization script remain disabled. SwiftPM and Docker executable paths use lethen; legacy configuration, library, cache, and Bazel names remain for compatibility. The commercial plan suggestion client is removed. Optional update checking points to `albovsky/lethen`; until a release exists, explicit `check-update` cannot find a latest release.

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
