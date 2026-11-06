# Xcode compilation caching and index units

[#196](https://github.com/albovsky/lethen/issues/196) asked whether Xcode's compilation caching (`COMPILATION_CACHE_ENABLE_CACHING=YES`) leaves compiled files without index units, which would make a managed `xcodebuild` scan report their targets as unused. It does, when the cache outlives a Lethen clean. This report records the experiment.

## Environment

- Host: arm64 macOS 27.2, build 26B123.
- Xcode: 27.0, build 27A266a. Apple Swift 6.4, swiftlang-6.4.0.34.1.
- Lethen: `c0ba30eb` (master), release build, `2026.10.1`.
- Fixture: a copy of `Tests/XcodeTests/UIKitProject`, scheme `UIKitProject`, built as `lethen scan --project UIKitProject.xcodeproj --schemes UIKitProject --format json -- -destination 'generic/platform=iOS Simulator'`, with the build setting under test appended after the destination.
- Units were listed with the `swift-index-store` reader Lethen uses (`IndexStore.units`, system units skipped), once per DerivedData store.

## What the cache does to the store

| Scan | Cache | `xcodebuild` | Non-system units | Findings |
| --- | --- | --- | --- | --- |
| 1. Caching off (default), `--clean-build` | none | full build | 70 | 27 |
| 2. `…=YES`, `--clean-build` | cold, inside DerivedData | full build | 70 | identical to 1 |
| 3. `…=YES` with `COMPILATION_CACHE_CAS_PATH` outside DerivedData, `--clean-build`, cold | cold | full build | 70 | identical to 1 |
| 4. Same arguments as 3, `--clean-build`, no source change: every compile is a cache hit | warm | build succeeds | no `Index.noindex` at all | exit 1: "Failed to find index datastore" |
| 5. Same arguments as 3, one comment added to `AppDelegate.swift`, `--clean-build` | warm | module `UIKitProject` misses, the other modules hit | **38 of 70** | **19 instead of 27, no warning about the cache** |

A cache hit does not write an index unit. The sources that lost their units in scan 5 are every file of the modules that hit: `LocalPackageTarget`, `NotificationService`, `Target_With_Spaces`, the `MultiTarget` and `InclusionFolder` files, `UIKitProjectTests` and `WatchWidget`. Scan 5 lost nine findings (for example `FileWithSpaces`, `LocalPackageUnusedType` and the `InclusionFolder` enums, which are no longer visible at all), added one wrong `likely` finding (`MultiTargetStruct.usedInExt`, whose user had no unit), and printed three "target … is not built by the scanned schemes" warnings that blame the schemes. The scan's exit status was 0; a second edit confirmed the same 19 findings.

With caching on, the SDK and module units also drop from 464 to 56 even on a miss; they are system units, which Lethen does not read, and the scan results were identical.

## When it applies

Lethen keeps each build in its own DerivedData directory and removes the directory before a clean build. By default the compilation cache lives inside it (`COMPILATION_CACHE_CAS_PATH = <DerivedData>/CompilationCache.noindex`), so a Lethen clean also empties the cache and every compile misses. With caching on and nothing else changed, three Lethen scans (clean; one-line edit, incremental; revert, incremental) kept all 70 units and produced findings identical to the baseline.

The cache can outlive a Lethen clean when something moves it outside DerivedData or shares it: `COMPILATION_CACHE_CAS_PATH` set in the project, an `.xcconfig` or the build arguments, or a remote cache such as Bitrise's, which Bitrise documents as leaving `Index.noindex/DataStore` unproduced (not reproduced here). Not tested here: `--skip-build` reading Xcode's own DerivedData after an IDE build with caching on, where the default cache path is shared across projects (`~/Library/Developer/Xcode/DerivedData/CompilationCache.noindex`).

## Decision

Units do go missing, so the fix in the issue applies: managed builds pass `COMPILATION_CACHE_ENABLE_CACHING=NO` after the user's build arguments, and `--skip-build` rejects a store in which a compiled file of a scanned target has no unit.
