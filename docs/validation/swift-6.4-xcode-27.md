# Swift 6.4 / Xcode 27 validation

This report records local and hosted evidence for the reliable-scanning milestone. Release installation is a separate gate; the completed private-project audit is summarized in [pett-audit.md](pett-audit.md).

## Environment

- Host: arm64 macOS 27.0, build 26A428.
- Xcode: 27.0, build 27A266a.
- Apple Swift: 6.4, swiftlang-6.4.0.34.1.
- SDKs: macOS, iOS/simulator, watchOS/simulator, tvOS/simulator, visionOS/simulator and DriverKit 27.0.
- Baseline source: `834c4f153a3b5e9d0da8441e045be49a1b7df678`.

## Discovery finding that changed the implementation plan

`swift build` defaults to automatic indexing. In Swift 6.4's swiftbuild engine, automatic indexes are under `.build/out`. However, `--enable-index-store` explicitly changes `SWIFT_INDEX_STORE_PATH` and `CLANG_INDEX_STORE_PATH` to `<binary directory>/index/store`. The actual fixture build request and emitted units confirmed this. Applying the original plan's automatic-layout mapping to an explicitly indexed build returned empty or stale results; the source-coverage regression caught it.

Lethen therefore enables indexing explicitly and resolves only `<swift build --show-bin-path>/index/store`, with the same effective build arguments for compilation and discovery. This also separates Debug and Release stores. The path is forwarded with `-Xswiftc -index-store-path`: a clean Release probe showed that the Swift compiler otherwise omitted indexing flags despite SwiftPM enabling the build setting. Managed discovery builds clean existing products in the selected scratch root before rebuilding. A final-review regression demonstrated that an external indexing-disabled build can leave an existing store stale, and index-only flag changes do not reliably invalidate Swiftbuild compilation. This correctness safeguard sacrifices incremental managed build speed; `--skip-build` reuses an index whose freshness the caller verifies. There is no fallback to an automatic store or another engine. `--skip-build` expects that same explicitly indexed location. For externally built automatic swiftbuild indexes, pass `--index-store-path /path/to/.build/out`; multiple explicit stores and an external JSON package manifest remain supported without discovery subprocesses.

The release discovery control now uses a dependency-free three-target package with normal release optimization. Its source coverage assertions exercise a main target, cross-module type, and external protocol under default and native engines. The initial AccessibilityProject control required `-enable-testing`; Linux Swift 6.1.3 then exposed an unrelated optimizer crash while deserializing its Foundation FileManager subclass. The dedicated fixture avoids that dependency, while the complete existing accessibility suite remains unchanged. Macro retention remains covered separately by SPMProjectTest.

## Regression evidence

- Working-directory regression: both new tests failed before the fix; all four FilePathTest tests passed afterward.
- Setup-state regression: missing helper failed compilation; original-error propagation and recovery passed after implementation.
- Compatibility failure check: the process exited 1 normally with the original missing index path and iOS 14.5 errors. XCTest recorded setup failures (and described aborted bodies as skipped); no `XCTSkip` or traps were introduced. Existing assertion lines were preserved.
- Xcode bundle after the four deployment-target edits: 22 tests passed, zero failures, 36.239 seconds. This includes SwiftUI entry points, UIKit/XIB and extension retention, and a scheme containing spaces. WatchOS 9.4 was preserved and built successfully.

## Local baseline

The unmodified `swift test` command passed all four targets, with zero failures and zero skips: XcodeTests 22, SPMTests 12, PeripheryTests 244, AccessibilityTests 41; **319 total**. The first complete run took 148.78 seconds. Product discovery fixes are in `6214ef3`; the confirmed dead frontend line-count field was subsequently removed in `d1d8d48`, after the strict self-scan reported it. A new strict clean self-scan then passed with no unused code. No baseline suppression was added.

`swift test --filter XcodeTests` also passed all 22 cases after the cleanup. The four changed iOS settings belong to SwiftUIProject and NotificationServiceExtension; other inherited targets were preserved. This validates indexing and scanner assertions, not runtime behavior on every deployment target.

Clean default, warm default, and clean native scans of `Tests/Fixtures` each returned 404 findings. Their canonical sets are identical, using `.github/scripts/canonicalize-scan-json.py`: relative file, line, column, kind, name, sorted hints and sorted IDs. Native flags were passed after the scanner's `--`, into the fixture build. No categories were discarded.

After the Pett-driven analysis fixes in `414cd82`, the complete local baseline script passed **321 tests**: XcodeTests 22, SPMTests 12, PeripheryTests 246, AccessibilityTests 41. Clean, warm, and native fixture scans agree on **419 findings**, including the added regression fixtures. Strict clean self-scan passed. The later dedicated discovery fixture passed locally and across the stable hosted matrix, including Linux Swift 6.1.3 with normal release optimization.

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

## Verified combinations

The stable matrix passed on release commit `04c6965`. These are specific build/scan checks, not a guarantee for every Swift 6.x release or deployment OS.

| Build toolchain | Scanned projects / engine | Host | Result / evidence |
| --- | --- | --- | --- |
| Apple Swift 6.4, Xcode 27.0 (27A266a) | SwiftPM default swiftbuild and native; Xcode fixtures | arm64 macOS 27.0, local 26A428 and CI 26A5406e | 322 tests, equal clean/warm/native scans, strict self-scan; [CI](https://github.com/albovsky/lethen/actions/runs/35466081905/job/105958543766) |
| Apple Swift 6.1.2, Xcode 16.4 | SwiftPM default/native; Xcode fixtures | arm64 macOS 15.7.9 (24G830) | Build, tests, strict self-scan [passed](https://github.com/albovsky/lethen/actions/runs/35466081905/job/105958543997) |
| Apple Swift 6.2.4, Xcode 26.3.0 | SwiftPM default/native; Xcode fixtures | arm64 macOS 26.6.2 (25G83) | Build, tests, strict self-scan [passed](https://github.com/albovsky/lethen/actions/runs/35466081905/job/105958543962) |
| Apple Swift 6.3.1, Xcode 26.4 | SwiftPM default/native; Xcode fixtures | arm64 macOS 26.6.2 (25G83) | Build, tests, strict self-scan [passed](https://github.com/albovsky/lethen/actions/runs/35466081905/job/105958543959) |
| Swift 6.1.3 / 6.2.4 / 6.3.3 | SwiftPM default/native | Linux x86_64, official Swift containers on Ubuntu 24.04.5 runners | Build, applicable tests, baseline-aware strict self-scan passed: [6.1](https://github.com/albovsky/lethen/actions/runs/35466081905/job/105958543982), [6.2](https://github.com/albovsky/lethen/actions/runs/35466081905/job/105958543905), [6.3](https://github.com/albovsky/lethen/actions/runs/35466081905/job/105958543939) |

All four Bazel 8.x/9.x macOS/Linux build-and-scan jobs also passed in the [same run](https://github.com/albovsky/lethen/actions/runs/35466081905). This does not establish a standalone Bazel distribution. Intel macOS, signed/universal binaries, and running a Swift 6.4-built binary on macOS 15 are not verified. The macOS 15 package minimum alone is not runtime evidence. Snapshot jobs remain allowed to fail and are not compatibility promises.

## Hosted CI

The [runner inventory](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md) was rechecked on 2026-09-19: `xcode-27` image 20260912.0186.1 lists Xcode 27.0 (27A266a), including the `/Applications/Xcode_27.0.app` symlink. The [failure probe](https://github.com/albovsky/lethen/actions/runs/35462247145/job/105948067914) used the real audit regression fixtures on `88b99c5`: the dedicated job failed exactly their four assertions and uploaded evidence. The [corrected baseline](https://github.com/albovsky/lethen/actions/runs/35462915861/job/105949919088) passed after `414cd82`; lint and all four Bazel jobs also passed. Linux Swift 6.1 exposed the fixture optimizer issue described above. All 12 non-optional matrix jobs subsequently passed on `fd7d268`, including the corrected Linux 6.1 release fixture. Final versioned installation evidence belongs to the release notes.

The repository API confirms `Swift 6.4 / Xcode 27` is a required status check on `master`, with an up-to-date-branch requirement. The dedicated job now checks out the PR head SHA explicitly, so final release evidence records the candidate itself rather than GitHub's synthetic merge commit. It uses no restored build/index cache and does not allow failure. The CI script records toolchain, commit and binary identity, all tests, canonical fixture comparisons, and strict self-scan; evidence uploads include hidden `.validation` files even after a failed gate.

## Final review regressions

Final review added a real package regression that builds without indexing after a source change, then verifies a managed build indexes the new declaration. It failed against the previous missing-store-only safeguard and passes with managed product rebuilding. The equality fixture now also covers a default witness on `Equatable where Self: Protocol`, with conformances declared both directly and in an extension; both unused-field assertions failed before the fix and pass afterward.

The final local suite passes 322 tests: XcodeTests 22, SPMTests 13, PeripheryTests 246, and AccessibilityTests 41. Clean default, warm reused-index (`--skip-build`), and clean native scans agree on 423 findings. The four added findings are exactly the new regression's two types, conformance extension, and unused comparison function; the previous 419 findings are unchanged. Strict clean self-scan passes. The final analysis also preserves all 154 restored Pett findings. Exact versioned CI and source-install evidence are linked from the GitHub release.

## Unreleased review fixes

The review follow-up fixes a false negative in the original equality model: constructing a value and reading one field could suppress diagnostics for every other field. Syntax metadata now connects whole-value operands to indexed types, including local bindings, typed closure parameters, and dictionary keys. The graph models omitted reads when these values reach an external API or a source-visible generic API that actually forwards generic values into a potential comparison. A generic constraint alone, or an unrelated comparison in that helper, does not qualify.

Regression controls cover construction without comparison, a source-visible identity helper with an unrelated comparison, direct and generic comparisons, library collection operations, nested values, typed closures, and dictionary subscripts. Existing custom-witness and unreachable-caller controls remain in place. Passing whole values to unindexed APIs remains conservative; this is not a general interprocedural type-inference engine.

Directory-change failures now use an accurate generic diagnostic instead of incorrectly classifying every failure as a missing file. The release discovery fixture copies only its manifest and source inputs. Managed SwiftPM rebuilds remain unchanged because removing them would restore the demonstrated stale-index defect. These changes are not included in the immutable `3.8.1-dev.1` tag.

Follow-up CI exposed a Linux FoundationNetworking teardown crash after successful Bazel scans. CI scan commands now disable update checks, matching the dedicated Xcode 27 gate and removing that unrelated network dependency. This does not establish a fix for update checks in ordinary CLI use.
