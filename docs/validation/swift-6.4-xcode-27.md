# Swift 6.4 / Xcode 27 validation

This report records local evidence for the reliable-scanning milestone. The Pett audit, hosted CI, and release installation remain separate gates.

## Environment

- Host: arm64 macOS 27.0, build 26A428.
- Xcode: 27.0, build 27A266a.
- Apple Swift: 6.4, swiftlang-6.4.0.34.1.
- SDKs: macOS, iOS/simulator, watchOS/simulator, tvOS/simulator, visionOS/simulator and DriverKit 27.0.
- Baseline source: `834c4f153a3b5e9d0da8441e045be49a1b7df678`.

## Discovery finding that changed the implementation plan

`swift build` defaults to automatic indexing. In Swift 6.4's swiftbuild engine, automatic indexes are under `.build/out`. However, `--enable-index-store` explicitly changes `SWIFT_INDEX_STORE_PATH` and `CLANG_INDEX_STORE_PATH` to `<binary directory>/index/store`. The actual fixture build request and emitted units confirmed this. Applying the original plan's automatic-layout mapping to an explicitly indexed build returned empty or stale results; the source-coverage regression caught it.

Lethen therefore enables indexing explicitly and resolves only `<swift build --show-bin-path>/index/store`, with the same effective build arguments for compilation and discovery. This also separates Debug and Release stores. The path is forwarded with `-Xswiftc -index-store-path`: a clean Release probe showed that the Swift compiler otherwise omitted indexing flags despite SwiftPM enabling the build setting. If products already exist without their matching store, lethen cleans that selected scratch root before rebuilding, because a warm swiftbuild can reuse objects after index-only flag changes. There is no fallback to an automatic store or another engine. `--skip-build` expects that same explicitly indexed location. For externally built automatic swiftbuild indexes, pass `--index-store-path /path/to/.build/out`; multiple explicit stores and an external JSON package manifest remain supported without discovery subprocesses.

The cold release control uses the existing AccessibilityProject fixture with `-Xswiftc -enable-testing`, because its tests use `@testable import`. Macro and cross-module retention remain covered separately by SPMProjectTest. This control does not claim that every package's release test build is supported.

## Evidence recorded so far

- Working-directory regression: both new tests failed before the fix; all four FilePathTest tests passed afterward.
- Setup-state regression: missing helper failed compilation; original-error propagation and recovery passed after implementation.
- Compatibility failure check: the process exited 1 normally with the original missing index path and iOS 14.5 errors. XCTest recorded setup failures (and described aborted bodies as skipped); no `XCTSkip` or traps were introduced. Existing assertion lines were preserved.
- Xcode bundle after the four deployment-target edits: 22 tests passed, zero failures, 36.239 seconds. This includes SwiftUI entry points, UIKit/XIB and extension retention, and a scheme containing spaces. WatchOS 9.4 was preserved and built successfully.

## Local baseline

The unmodified `swift test` command passed all four targets, with zero failures and zero skips: XcodeTests 22, SPMTests 12, PeripheryTests 244, AccessibilityTests 41; **319 total**. The first complete run took 148.78 seconds. Product discovery fixes are in `6214ef3`; the confirmed dead frontend line-count field was subsequently removed in `d1d8d48`, after the strict self-scan reported it. A new strict clean self-scan then passed with no unused code. No baseline suppression was added.

`swift test --filter XcodeTests` also passed all 22 cases after the cleanup. The four changed iOS settings belong to SwiftUIProject and NotificationServiceExtension; other inherited targets were preserved. This validates indexing and scanner assertions, not runtime behavior on every deployment target.

Clean default, warm default, and clean native scans of `Tests/Fixtures` each returned 404 findings. Their canonical sets are identical, using `.github/scripts/canonicalize-scan-json.py`: relative file, line, column, kind, name, sorted hints and sorted IDs. Native flags were passed after the scanner's `--`, into the fixture build. No categories were discarded.

Coverage includes AppIntent/AppEntity/AppEnum/AppShortcutsProvider; SwiftUI App and UIApplicationDelegateAdaptor entry points and library providers; ObjC accessibility/annotations; Codable/Encodable retention; XCTest and Swift Testing declarations; macro imports; cross-module references; XIB/storyboard/Info.plist retention; and redundant-public analysis. Tests retain both used and unused controls. The default CLI SPMProject scan reports `PublicCrossModuleNotReferenced` and retains `PublicCrossModuleReferenced`.

Evidence commands:

```sh
swift test
swift test --filter XcodeTests
lethen_bin_dir="$(swift build --show-bin-path)"
"$lethen_bin_dir/lethen" scan --project-root Tests/Fixtures --clean-build --quiet --disable-update-check --format json --relative-results
"$lethen_bin_dir/lethen" scan --project-root Tests/Fixtures --quiet --disable-update-check --format json --relative-results
"$lethen_bin_dir/lethen" scan --project-root Tests/Fixtures --clean-build --quiet --disable-update-check --format json --relative-results -- --build-system native
"$lethen_bin_dir/lethen" scan --quiet --clean-build --strict --disable-update-check
```

Raw local logs and canonical JSON are under `.validation/`, outside SwiftPM scratch directories. The dedicated CI script recreates this evidence and uploads it even on failure. Raw Pett reports remain outside the public repository.

## Compatibility boundaries

| Toolchain / host | Scanned project | Result |
| --- | --- | --- |
| Swift 6.4, Xcode 27.0, arm64 macOS 27.0 | SwiftPM default swiftbuild and native; Xcode fixtures | Local tests and comparisons passed |
| Same | SwiftPM Release with testable imports enabled | Explicit-index discovery and source coverage passed under both engines |
| Older Swift/Xcode, Linux, Bazel, Intel | Any | Not locally verified; existing CI jobs preserved |
| macOS 15 runtime | Any | Not tested; package minimum alone is not runtime evidence |

## Hosted CI

The [runner inventory](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md) was rechecked on 2026-09-19: `xcode-27` image 20260912.0186.1 lists Xcode 27.0 (27A266a), including the `/Applications/Xcode_27.0.app` symlink. Hosted runs and required-check configuration are pending. A workflow definition alone does not establish branch protection or compatibility.

