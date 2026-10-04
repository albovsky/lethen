# Scan performance

This report records how long Lethen scans take, where the time goes, and what the Phase 1
speed work changed. Every number states the build and project behind it. Timings are wall
clock from starting `lethen` to its exit, unless a row names a phase from `--stats`.

## Environment

- Apple Swift 6.4 (swiftlang-6.4.0.34.1), Xcode 27.0 (27A266a), macOS 27.0, Apple silicon (arm64).
- `lethen` built with `swift build -c release`, which is how releases and Homebrew build it.
- Scans use the default debug configuration and the default SwiftPM build system (Swift Build).

## Summary

| Measure | Before Phase 1 | Now |
|---|---|---|
| Lethen scanning itself, nothing changed | 33.8 s | 5.3 s |
| Lethen scanning itself, after editing one widely imported module | 33.8 s | 17.0 s |
| Indexing and analysis of about 100,000 lines of code | not measured | 1.7 s (1.0 s index, 0.7 s analyze) |
| Identical scans of the same index store | results could differ between runs | byte-identical |

The Phase 1 target of analysis under 5 s per 100,000 lines on Apple silicon is met with room to
spare. What a scan costs is the build: a managed SwiftPM scan cleaned and rebuilt everything,
including dependencies, on every run.

## Managed SwiftPM scans: clean versus verified reuse

Lethen scanning its own repository (205 files, 15,937 lines of code), measured with the release
build of the verified index reuse from albovsky/lethen#39, which managed SwiftPM scans now use by
default; `--clean-build` gives the clean column. Every reuse scan's findings were compared with a
clean scan of the same sources and matched.

| Situation | Clean (`--clean-build`) | Verified reuse (default) | What reuse recompiled |
|---|---|---|---|
| Nothing changed since the last scan | 33.8 s | 5.3 s | nothing |
| A test file edited, no build in between | 33.8 s | 7.4 s | 1 module |
| `Frontend` edited, no build in between | 33.8 s | 10.5 s | 3 modules (`Frontend` and its importers) |
| `Shared` edited and built with a plain `swift build` | 33.8 s | 17.0 s | 15 modules (`Shared` is imported by nearly every module) |
| First scan, or different build arguments | 33.8 s | 32.5 to 36.1 s | everything (falls back to a clean build) |

Reuse recompiles a whole module and every module that imports it, because incremental builds do
not always recompile an importer when the imported module's interface changes; the importer's
index then references declarations that no longer exist. The cost of an edit therefore depends on
where it is, but never includes the package's dependencies.

The two test fixture packages, rescanned with nothing changed:

| Package | Clean (`--clean-build`) | Verified reuse (default) | Findings |
|---|---|---|---|
| `Tests/Fixtures` | 15 s | 4 s | 435, identical |
| `Tests/SPMTests/SPMProject` (macro target) | 15 s | 5 s | 4, identical |

## Packages with targets the build never compiles

albovsky/lethen#89: a target that `swift build --build-tests` does not compile, such as an
executable used only by a command plugin, has no index units, so the index could never be
verified and every scan cleaned. Lethen now records such targets in the build stamp and reuses
the tree while they still have no objects.

Measured on swift-argument-parser at 1021ac8, whose `generate-docc-reference` and
`generate-manual` executables are used only by command plugins. Environment for this table:
Linux x86_64, Swift 6.4 (swift-6.4-RELEASE), the default Swift Build system, debug configuration,
and `lethen` built with `swift build -c release` from this change on top of d7dec6c. These are
not the Apple silicon numbers above. The command is `lethen scan --retain-public --format json
--verbose`, each time from the same checkout.

| Situation | Time | Log |
|---|---|---|
| First scan, no `.build` | 38.2 s | no matching build stamp, cleaning |
| Rescan, nothing changed | 4.6 s | reused; recompiled 0 modules |
| Rescan with `--clean-build` | 39.1 s | cleaned |
| After `swift build --product generate-manual` | 38.9 s | `generate-manual` was recorded as not built but now has objects, cleaning |
| Rescan after that | 4.5 s | reused; recompiled 0 modules |

The findings of the first, reused, and post-build scans are byte-identical; the `--clean-build`
scan differs only by the `clean_build: true` line the output echoes. Without `--retain-public`,
the scan warns that the two tools are not scanned and names the modules to pass to
`--retain-public-targets` (`ArgumentParser`, `ArgumentParserToolInfo`).

## Where a scan's time goes

`--stats` (albovsky/lethen#40) on an app of 650 Swift files and 101,525 lines of code (blank and
comment-only lines excluded), scanned with `--skip-build` against the index Xcode keeps for it:

| Phase | First run | Warm run |
|---|---|---|
| Setup (`xcodebuild -list`, project parsing) | 3.6 s | 3.3 s |
| Index: plan (reading the store and project files) | 1.8 s | 0.35 s |
| Index: Swift phase one | 0.45 s | 0.42 s |
| Index: Swift phase two | 0.23 s | 0.21 s |
| Analyze (source graph mutators) | 0.70 s | 0.71 s |
| Total | 6.8 s | 5.0 s |
| Throughput (index and analyze) | 31,663 lines/s | 59,170 lines/s |

Indexing and analysis are not where time goes, so the roadmap's candidate optimizations for them
(a per-file syntax cache, batched graph mutations, concurrent mutators) are not needed to meet the
target and were not built. The largest remaining cost without a build is setup. Project parsing for
this app took 54 s in a debug build before albovsky/lethen#42 stopped walking its synchronized
folders once per target and three times over; it takes 25 s in a debug build now.

## Xcode scans: reusing a completed build

Wikipedia iOS (`599e4a6`, `--project Wikipedia.xcodeproj --schemes Wikipedia`, destination
`generic/platform=iOS Simulator`), Xcode 27.0 (27A266a), Swift 6.4, `lethen` built with
`swift build -c release`, 1,299 source files and 152,815 lines. Wall clock, one scan per row:

| Scan | Before | After |
|---|---|---|
| `--clean-build` | 203.1 s | 199.7 s |
| Rescan 1 (after the clean build) | 143.3 s | 147.2 s |
| Rescan 2 | 24.2 s | 7.1 s |
| Rescan 3 | 24.0 s | 7.0 s |
| Rescan after editing `AppDelegate.swift` | not measured | 40.2 s |

Before is Lethen at 42a17ea, which never reused this build; after is this change. Rescans 2 and 3 run no
`xcodebuild` (`--verbose` says it reuses the build) and their findings are byte-identical to each other, to the
edited-file rescan, which builds again and takes it into account, and to the same rescans on the build that ran
every time. Rescan 1 still builds: the `swiftlint --fix` phase edits Swift sources while the clean build runs, so
the first rescan finds 14 indexed files newer than their units and rebuilds; every later one starts from a
settled tree.

Two things kept Wikipedia from reusing its build before. The build rewrites `Localizable.strings` and the
`.lproj` folders in `Wikipedia/Localizations` and `WMFLocalizations` after it starts, and Lethen required every file
and folder to predate the start. And a Run Script phase is set to run on every build, which switched reuse off.
Lethen now compares only the files a scan reads (sources, headers, project and build setting files, schemes,
plists, nibs, Core Data models and declared Run Script inputs), records them when a build starts so an added,
removed or renamed one is a change, and ignores folder times and the rest, so the strings rewrite no longer
counts. A phase set to run on every build disables reuse only when it names a path Lethen cannot resolve or
writes a source it cannot check. Wikipedia's declared outputs go to `$(TARGET_BUILD_DIR)`, the product folder, and
its generated `OpenSourceDebug.xcconfig`, which `scripts/setup_bundle_id` writes and git ignores, does not exist
in a fresh checkout; neither blocks reuse.

The `XcodeBuildReuseTest` cases check this with real builds: a second build runs no `xcodebuild`, a strings file
rewritten or added still reuses, and an edit, an added or deleted source, a rewritten header, a changed project
file or a unit older than its file each bring the build back. On Wikipedia reuse saves the 17 s build of a
no-change rescan, which is 24 s without it.

## Determinism

The same app's index was scanned six times with an explicit `--index-store-path`. Before
albovsky/lethen#42 the six runs produced six different result sets (185 to 200 findings) and 33 to
34 declaration conflict warnings each, because the index held units for several versions of the
same files. After it, all six runs are byte-identical: 198 findings and no conflicts.

## Reproducing

```sh
swift build -c release --product lethen
LETHEN="$(swift build -c release --show-bin-path)/lethen"

# Clean managed scan, then verified reuse (the default; the first scan after a clean builds and stamps)
"$LETHEN" scan --disable-update-check --format csv --clean-build
"$LETHEN" scan --disable-update-check --format csv --verbose

# Phase timings and project size
"$LETHEN" scan --disable-update-check --format csv --stats
```

With `--verbose`, the reuse scan logs whether it reused the index and which modules it recompiled,
or why it cleaned.
