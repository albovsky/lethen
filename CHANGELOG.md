## master

##### Breaking

- Managed SwiftPM scans no longer clean before every build. Lethen reuses the previous build when it can verify the index: it recompiles every module that another build or an edit touched, together with the modules that import it, checks the index afterwards, and cleans and rebuilds when anything cannot be verified. A rescan of Lethen itself with nothing changed takes 5.3 s instead of 33.8 s. `--clean-build` restores the previous behavior.

##### Enhancements

- Lethen reads the index clang writes for C and Objective-C files, so a Swift declaration that Objective-C code uses, such as an `@objc` method called from a `.m` file, a class allocated there, or a class named in a header, is no longer reported as unused without `--retain-objc-accessible`. `lethen explain` names the Objective-C line that uses it. Uses are matched by the symbol's clang USR and never guessed; `@class` and `@protocol` forward declarations do not count as uses, and Objective-C declarations themselves are not analyzed, so a use counts even from Objective-C code that is itself unused. Exposed declarations with no reference are still `likely`.
- `lethen explain <name|usr>` scans like `lethen scan` and explains one declaration: why it is reported as unused, the shortest chain of references that makes it used, or the rule or comment that retains or ignores it.
- Lethen's package includes a command plugin, `LethenPlugin`: `swift package --allow-writing-to-package-directory --allow-network-connections all lethen` scans a package, building it with indexing in `.build/lethen`, and an Xcode command scans an Xcode project from the index Xcode keeps and reports results as Xcode issues. The package must be added with a branch or commit rule because Lethen depends on swift-index-store by commit.
- `mint install albovsky/lethen` is supported and documented.
- `lethen scan --stats` prints the time spent in each scan phase, the number of Swift files, lines of code, and declarations scanned, and the indexing and analysis throughput. The report goes to standard error, so `json` and `csv` results on standard output stay valid. Lines of code are now counted only for `--stats`; scans without it no longer walk every token to count them and discard the result.
- Managed `xcodebuild` and `swift build` runs show that they are still working. The default output prints `Still building (Ns elapsed, step n/m)` to standard error every 15 seconds, `--verbose` streams the full build output to standard error, and `--quiet` and machine-readable formats print nothing, so results on standard output stay valid.
- `--skip-build` without `--index-store-path` also finds the index Xcode keeps for the project in its DerivedData and uses whichever index was written most recently, so a project Xcode has indexed can be scanned without an `xcodebuild` build. Such an index is checked first: units older than their source file are ignored, and a source file newer than every unit for it stops the scan with a stale-index error instead of producing results from outdated code. The same check now applies to SwiftPM `--skip-build` scans without an explicit path.
- Xcode projects that use file system synchronized groups are parsed faster: the group tree is walked once per project instead of three times per target.
- The repository has a precision corpus: `corpus/projects.json` pins Alamofire, swift-nio, and Wikipedia iOS, `corpus/scan.sh` scans one at its pinned commit, and `corpus/diff.sh` compares the result with the findings committed under `corpus/expected/`, so an analysis change shows exactly which findings it adds or removes on real code. The nightly `Precision corpus` CI job scans every project and fails on any unadjudicated difference. `docs/validation/precision-corpus.md` publishes the adjudicated sample and the precision scorecard.
- Every result has a confidence, `certain` or `likely`. It is `likely` when the declaration is accessible from Objective-C without `--retain-objc-accessible` or `--retain-objc-annotated`, or when it is a type, method, property, or enum case whose name appears in a symbol-shaped string literal in the scanned sources, such as a selector string, a class name, or a key path. Prose literals such as log messages do not count; on swift-nio this marks 20 of 434 findings `likely`. JSON output has a `confidence` key, CSV output ends with a `Confidence` column, and every format lists `certain` results first. Confidence does not change what a baseline filters, and it changes what is reported only under `--min-confidence certain`.
- `--min-confidence certain` (`min_confidence: certain` in the configuration file) reports only `certain` results, so `lethen scan --min-confidence certain --strict` fails CI only on results Lethen is sure about. It runs after the baseline, so it also decides what `--strict` counts and what `--write-baseline` records, and it prints how many results it hid to standard error unless `--quiet` is given. The default, `likely`, reports everything as before. JSON results have a `confidenceReason`, `null` for `certain` results.
- JSON results have a `reason`, one sentence on why the declaration is reported, such as `no references in the scanned modules` or `referenced only from 2 unused declarations`. Text formats append `[likely: <why>]` to `likely` results, and `lethen explain` prints the confidence of every reported declaration.
- The `xcode` format ends with a summary on standard error: the number of results and how many are `likely`, how many `--min-confidence` hid (in place of its separate line), and pointers to `lethen explain` and `--write-baseline`. Standard output is unchanged, `--quiet` suppresses the summary, and other formats never print it. Under `--verbose` each result is followed by an indented line with its reason, and CSV output ends with a `Reason` column after `Confidence`.
- `--configurations debug release` builds a Swift package in each configuration and scans their index stores together, so code used only behind `#if DEBUG`, or only in release builds, is no longer reported as unused. A configuration that fails to build fails the scan. Xcode projects accept the option too: `--configurations Debug Release` runs `xcodebuild build-for-testing -configuration <name>` for each configuration, each into its own DerivedData directory, and scans their index stores together; the names must be build configurations of the project. Bazel and generic projects reject the option.
- Xcode scans name the configuration each build compiles, such as `Building Wikipedia with configuration Test`, read from the scheme's Test action. When that differs from the configuration the scheme runs with and neither `--configurations` nor `-configuration` is given, Lethen warns that code compiled only in the run configuration is reported as unused and names the `--configurations` flag that scans both. The default build is unchanged.
- `--retain-public-targets <module>…` retains the public API of the listed modules only, for local packages whose consumers or tests are outside the scan. Swift package scans that exclude tests or targets warn when an excluded target depends on a scanned one and name the modules to retain.
- Enum cases that are only ever matched in patterns and never constructed are reported with the new hint `unconstructedEnumCase` ("Enum case 'x' is matched but never constructed"). Raw-value, `CaseIterable`, `Codable`, `@objc`, and retained enums are skipped. On the precision corpus it reports 56 cases, all adjudicated as dead. One of them was in Lethen itself, `SetupSelection.all`, which is removed.
- Unused parameters of subscripts, and of closures stored in a property or global variable, are reported like unused function parameters. A subscript that satisfies another module's protocol requirement keeps its parameters.
- The repository is a GitHub Action: `uses: albovsky/lethen@<version>` downloads that release's binary for the runner (Apple silicon macOS, or Linux x86_64 or aarch64), verifies it against `SHA256SUMS`, caches it in the runner's tool cache, and runs `lethen scan` with annotations on the pull request. Inputs cover the version (`latest`, or `source` to build the action's checkout), extra arguments, the working directory, a baseline, strictness, the output format, and `--min-confidence`; outputs are the result count and the results file. On Linux the job needs a Swift 6.3 or later toolchain on `PATH`. The `Action smoke` workflow runs the action on Linux and macOS for pull requests that change it and nightly against the latest release.

##### Bug Fixes

- Xcode builds with different build arguments no longer share one DerivedData directory. Lethen's DerivedData path is also keyed by the build arguments when any are given, so a scan with `-- -configuration Release` no longer overwrites the index units of a scan without it. The first scan with build arguments after upgrading builds from clean.

- C, C++, and Objective-C files in the index store are no longer parsed as Swift. Their index units reached the Swift indexer, which parsed each file with SwiftSyntax, so string literals in Objective-C and C code made Swift declarations with the same name `likely` instead of `certain`, and `--stats` counted their lines. The files are now told apart by the compiler that indexed them and skipped.
- The Linux release tarballs run on Ubuntu 26.04, including the `swift:6.4` and `swift:6.4-resolute` images. The 3.9.0 executable linked the system's `libxml2.so.2`, which Ubuntu 26.04 replaced with `libxml2.so.16`, so it failed to start there. The executable now links libxml2 statically, built from Ubuntu 22.04's patched source without ICU, zlib, or liblzma, and the tarball includes libxml2's license. The release build fails if the executable needs a shared library outside a fixed list that every supported distribution ships, and the tarballs are smoke-tested on Ubuntu 22.04, 24.04, and 26.04 images with a scan that parses a XIB.
- Under `--retain-public`, and for modules listed in `--retain-public-targets`, unused parameters of retained public API are no longer reported: parameters of a public or open function, of any function in the same override chain, and of a public protocol's requirements together with every witness and its overrides. The API fixes these signatures, so such a finding could not be acted on without breaking clients. Functions in an `_spi` group listed in `--no-retain-spi` are still analyzed, and `lethen explain` names the rule for a parameter it retains. On the precision corpus this removes 13 findings from Alamofire and 55 from swift-nio; 5 of the Alamofire rows were real but unfixable without an API change, such as a public method that ignores its argument.
- Unused parameters of a function referenced as a value are no longer reported: a function passed as an argument, assigned to a function-typed variable, or named in `#selector` has its signature fixed by the function type, and so do the other functions in its override chain and the witnesses of the same protocol requirement. The index's call role tells a value reference from a call, so a function that is only called, including from inside a closure, is still analyzed. `lethen explain` names the rule for a parameter it retains. On the precision corpus this removes 7 findings from swift-nio, all false positives.
- Unused parameters of a witness of an underscored standard library requirement, such as `_failEarlyRangeCheck(_:bounds:)` on a `Collection` or `_rawHashValue(seed:)` on a `Hashable` type, are no longer reported. The index records no relation to underscored requirements of the standard library, so such a witness looked like an ordinary method even on an internal type; Lethen now recognizes the standard library's underscored requirements that take parameters by name, on a type that conforms to a protocol from another module. An underscored method with any other name is still analyzed, and `lethen explain` names the rule. On the precision corpus no rows change: the witnesses in swift-nio are public and already kept under `--retain-public`.
- Metatype parameters that select a generic type, such as `_ type: T.Type = T.self` or `as: (T1, T2).Type = (T1, T2).self`, are no longer reported as unused. Such a parameter was already treated as used without a default value, but a default value, a tuple of generic parameters, or a generic parameter of the enclosing type (or of an extended type declared in the same file) was missed. On the precision corpus this removes 16 false positives from Alamofire and 68 from swift-nio. Metatypes of concrete types are still reported.
- Result builder methods are retained by their base name, so `buildPartialBlock`, a `buildBlock` with several parameters, and labeled overloads such as `buildExpression(_:scale:)` are no longer reported as unused. Methods with those names on a type that is not a `@resultBuilder` are still reported.
- Property wrapper initializers the compiler calls, `init(wrappedValue:…)` with any further labels and `init(projectedValue:)`, are no longer reported as unused. Other initializers of a property wrapper are still reported.
- Document classes named by `NSDocumentClass` in an Info.plist's `CFBundleDocumentTypes` are retained, like the principal and scene classes already were, so a document-based app's `NSDocument` subclass is no longer reported as unused.
- Stored properties of an `Encodable` struct without its own `encode(to:)` are no longer reported as unused or assign-only when a value of the struct reaches an encoder: an unindexed call such as `JSONEncoder().encode(_:)`, or a scanned function that is generic over `Encodable` or takes `any Encodable`. Structs stored in such properties count as encoded too. This models synthesized `encode(to:)` the way synthesized `==` already was; on Alamofire it removes 11 false positives. `--retain-codable-properties` and `--retain-encodable-properties` still retain every such property.
- A type whose only user is its own macro expansion is reported as unused. Declarations a macro generates were each retained on their own, so the extension `@Observable` generates (`extension Foo: Observable`) kept `Foo` alive even when nothing used it. Generated members are now retained through the declaration they belong to, and generated extensions are folded into the type they extend like any other extension. Parentless expansions, such as `#Preview`, are unchanged.
- `swift package describe` now receives the build's `--scratch-path`, `--disable-sandbox`, and `--disable-keychain`, like `swift package clean` already did for the scratch path. Without the scratch path it locked the default `.build`, so a scan waited forever while another SwiftPM process held that lock.
- XcodeProj is capped at 9.10.x, the version Lethen is tested with. Packages that depend on Lethen resolve XcodeProj themselves, and 9.11 and later add enum cases Lethen does not handle, so they could not build it.
- Scans of an index store holding units for several versions of one file, such as an Xcode index built for several destinations over time, gave different results from run to run: the versions' declarations conflicted, and which one won depended on hash and thread order. Each file is now indexed from one version (the units written after the file last changed, or else the most recently written version), declarations whose USRs collide are chosen in a fixed order, and removing a declaration no longer unmaps a USR that a conflicting declaration owns. On an app of about 100,000 lines, six identical scans had given six different result sets; they are now identical.
- Redundant protocol conformance locations are listed in file, line, and column order in every output format. They previously followed per-process hash order, so identical scans of a protocol with several conformances could produce different output, contrary to the byte-identical output claimed in 3.9.0.

## 3.9.0 (2026-09-25)

Lethen now requires Swift 6.3 (Xcode 26.4) and publishes Linux release tarballs alongside the Apple silicon macOS binary and Homebrew formula.

##### Breaking

- The minimum supported Swift version is now 6.3 (Xcode 26.4). Lethen supports the current Xcode major and the final release of the previous major.
- macOS release binaries and the Homebrew formula are Apple silicon only; the universal macOS binaries provided by upstream Periphery are not provided by lethen. Intel users must build from source within the [supported Xcode 26 window](CONTRIBUTING.md#supported-platforms).

##### Enhancements

- Pushing a version tag publishes a signed, notarized Apple silicon macOS binary on the GitHub release after smoke tests, and stable versions update the `albovsky/tap/lethen` Homebrew formula. Intel Macs build from source.
- Releases include Linux tarballs for x86_64 and aarch64, for glibc 2.35 or later and Swift 6.3 or newer. The tarball's `bin/lethen` finds the indexing library of the active toolchain, including swiftly installs.

##### Bug Fixes

- The mise build task no longer attempts Intel or universal builds; `--arch release` produces a stripped arm64 binary. The benchmark runs the executable path returned by the build task instead of assuming `.build/release/lethen`. The build uses standard release optimization to avoid ArgumentParser linker failures with explicit cross-module optimization on Xcode 27.
- The `csv` format quotes fields that contain commas, quotes, or line breaks, such as `@available` attributes with arguments and redundant-conformance hints naming several protocols, so every row keeps eight columns.
- The `json`, `codeclimate`, and `gitlab-codequality` formats write object keys in sorted order, so identical scans produce byte-identical output.
- Xcode scans of two or more schemes reuse one DerivedData directory instead of creating a new one on most runs, because the schemes are sorted before the directory name is hashed. Builds are incremental again and orphaned directories no longer accumulate; caches left under the old names are not migrated, and `lethen clear-cache` removes them.
- The update check no longer crashes the process on Linux with Swift 6.4. Its session is invalidated once the request settles or is abandoned, and it stays alive until the process exits.

## 3.8.1 (2026-09-25)

The first lethen release. Lethen is an independent, MIT-licensed fork of Periphery 3.8.0; tags through 3.8.0 are upstream history. This is the last release that supports Swift 6.1 and 6.2; 3.9.0 requires Swift 6.3 (Xcode 26.4).

##### Breaking

- None.

##### Enhancements

- The executable is `lethen`. User-facing messages, the guided setup, the bug report template, and the mise Docker tasks name lethen; the historical upstream guide no longer carries the commercial banner, sponsor material, or upstream images. Existing `.periphery.yml` files, `// periphery:` comment commands, the `PeripheryKit` library, and the `periphery` Bazel module remain supported.
- The optional update checker reads lethen's releases; development builds are offered newer development releases, stable builds only stable releases.
- Bazel mode warns when `MODULE.bazel` has no source override for the `periphery` module, and `lethen scan --setup` prints the override snippet for the installed version.

##### Bug Fixes

- Managed SwiftPM scans resolve the active binary directory and enable indexing explicitly, including release builds, so the index store is found on Swift 6.4 / Xcode 27, and a missing store fails with an actionable error. Managed scans rebuild existing products to rule out a stale index; use `--skip-build` with `--index-store-path` for an index you know is current.
- Generated SwiftUI state projections are connected to their source property, so state used only through its binding is no longer reported as unused.
- Properties read only by synthesized `Equatable` and `Hashable` conformances are no longer reported as assign-only when a value reaches a comparison.
- Top-level code in `main.swift` no longer attributes its references to the nearest preceding declaration.
- The update check no longer crashes the process on Linux after a successful scan.
- The guided setup reports an error instead of crashing when no project is detected, and fails instead of looping forever when input ends; `--project` on Linux is a usage error; a missing or unparseable Swift toolchain is reported instead of crashing; errors thrown by concurrent indexing jobs are collected safely.

## 3.8.0 (2026-07-25)

##### Breaking

- None.

##### Enhancements

- Added the `--retain-equatable-properties` and `--retain-hashable-properties` options to retain all properties on `Equatable` and `Hashable` types.
- Expose a stable `@periphery//bazel:generated` package group so Bazel projects can grant visibility to Periphery's generated scan target and use `--bazel-check-visibility` safely.
- Added a `--bazel-query` option to override the default Bazel top-level target query.

##### Bug Fixes

- Follow embedded bundle and plugin edges transitively in the generated Bazel scan rule so custom Bazel queries can avoid building incorrectly transitioned targets while still analyzing extension- and plugin-reachable code.
- The `--write-results` file is now written even when a scan produces no results, instead of being left absent from a prior run.

## 3.7.4 (2026-04-26)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- Fix Homebrew releases.

## 3.7.3 (2026-04-25)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- Fix mixed Swift/Objective-C indexing failures caused by non-Swift symbols being processed from the index store, which could trigger unknown extension reference errors and duplicate declaration conflicts.

## 3.7.2 (2026-03-31)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- Fix Homebrew Linux builds failing to link `libIndexStore` when Swift is resolved through shimmed toolchain paths.

## 3.7.1 (2026-03-31)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- Fix runtime crash due to absolute libIndexStore.dylib path in pre-built binary.
- Fix building on Linux with SwiftPM and non-standard Swift install location for Homebrew release.

## 3.7.0 (2026-03-30)

##### Breaking

- None.

##### Enhancements

- Added support for Bazel 9.x.

##### Bug Fixes

- Fix false positive redundant public accessibility for types used in typed throws clauses, e.g. `throws(MyError)`.
- Fix false positive superfluous ignore comment results for assign-only properties.
- Fix incorrect generic protocol extension handling in Swift 6.2.4.

## 3.6.0 (2026-02-18)

##### Breaking

- The minimum supported Swift version is now 6.1.2.

##### Enhancements

- Added the `--bazel-check-visibility` to disable passing `--check_visibility=false` to `bazel run`.

##### Bug Fixes

- Fix some causes of potentially non-deterministic results.
- Fix incorrect superfluous ignore comment results for protocol members.

## 3.5.1 (2026-02-15)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- Fix false positive redundant public accessibility for types used in same-type generic requirements on extensions, e.g. `extension SomeProtocol where Self == MyType`.
- Exclude declarations ignored by a file-level `// periphery:ignore:all` comment from superfluous ignore comment detection.
- Superfluous ignore comment results are now included in baselines.

## 3.5.0 (2026-02-11)

##### Breaking

- The `--no-color` option has been replaced with `--color=never`.

##### Enhancements

- The `--color` option now accepts one of `auto`, `always` and `never`. In `auto` mode, color is disabled for dumb terminals and non-TTYs.
- Added detection of superfluous `// periphery:ignore` comments. A result is now reported when an ignore comment is unnecessary because the declaration is actually used. Can be disabled with `--no-superfluous-ignore-comments`.
- More unused code is now reported in a single scan, rather than requiring repeated remove-and-rescan cycles.

##### Bug Fixes

- Fix IBAction methods with named parameters or no parameters incorrectly marked as unused.
- Fix `--retain-swift-ui-previews` for the `#Preview` macro.

## 3.4.0 (2026-01-06)

##### Breaking

- None.

##### Enhancements

- Added the `--no-color`/`--color` option to disable/enable colored output.
- Added the `--no-retain-spi` option to not retain the given SPI (System Programming Interface) attributed members when using `--retain-public`.
- Exclude wrapped properties from assign-only analysis, as Periphery cannot observe the behavior of the property wrapper.
- Improved the readability of result messages.
- Improved Interface Builder file parsing to detect unused `@IBOutlet`, `@IBAction`, `@IBInspectable`, and `@IBSegueAction` members. Previously, all `@IB*` members were blindly retained if their containing class was referenced in a XIB or storyboard.

##### Bug Fixes

- Fix redundant public accessibility false positive for types referenced via static members in property initializers.
- Fix inline ignore comment not working on properties.
- Fix false positive when a constrained protocol extension provides a default implementation that satisfies a requirement of the constraining protocol.
- Fix indexing of xib/storyboard files in SPM projects.
- Fix types conforming to App Intents protocols being reported as unused.
- Fix superclass initializer reported as unused when called on subclass.
- Fix unused parameter false-positive for parameters used in closure capture lists.
- Fix sorting of results with a location override.

## 3.3.0 (2025-12-13)

##### Breaking

- None.

##### Enhancements

- Added the `--retain-unused-imported-modules` option.
- Added the `--format gitlab-codemagic` formatting option for GitLabs Code Quality artifact reports
- Added the `--bazel-index-store` option to specify the path of a global index store.

##### Bug Fixes

- Fix concurrent mutation crash.
- Fix unused import false-positive for when a declaration's associated types are declared in different module than module that declares the declaration.
- Fix unused import false-positive for modules that export unindexed modules.
- Exclude conditionally imported modules from unused import detection, as they may provide symbols for code that was not compiled.
- Fix `--retain-assign-only-property-types` for properties with trailing comments.
- Fix unused parameter analysis for parameters with name enclosed by backticks.
- Fix indexing of Xcode resources (storyboards, etc.) in projects using file system folders.
- Fix infinite loop loading Xcode projects with circular references.

## 3.2.0 (2025-06-27)

##### Breaking

- The `bazel-out` directory is no longer automatically excluded from results to allow for the detection of unused code in generated files. Use `--report-exclude "**/bazel-out/**/*"` to apply the previous behavior.

##### Enhancements

- Added the `--write-results <file>` option.
- Added the `github-markdown` output format.
- Added the ability to override the result location and kind with a comment command. This can be used in cases where the unused code exists in a generated source file, but the code to be removed exists in another file.
  ```swift
  // periphery:override location="some/dir/en.lproj/Feature.strings:1:1" kind="localized string"
  var generatedProperty: String = "abc123"
  ```
  ```
  some/dir/en.lproj/Feature.strings:1:1: warning: Localized string 'generatedProperty' is unused
  ```

##### Bug Fixes

- Fix unused import false-positives where the only referenced declaration is generated by a macro.
- Fix building with Bazel on Linux by excluding Xcode support.
- Fix slow baseline filtering for large projects with many results.
- Fix inconsistent unused parameter results when the function is declared in a file that is a member of multiple targets.
- Fix inconsistent results caused by identical extensions declared in different modules.
- Static `@_dynamicReplacement` members are now retained.
- Fix possible concurrent mutation crash when accessing filename matching configuration options.

## 3.1.0 (2025-04-05)

##### Breaking

- Assign-only property analysis is disabled with Swift 6.1 due to a Swift bug: https://github.com/swiftlang/swift/issues/80394.

##### Enhancements

- Comment commands can now be placed inline with declarations:
  ```swift
  class Foo { // periphery:ignore
    ...
  }
  ```

##### Bug Fixes

- Unused parameter warnings are suppressed in `@available(*, unavailable)` functions.
- Fix handling of Xcode projects with single and double quotes in their path and scheme names.
- `@_dynamicReplacement` members are now retained.
- Fix infinite loading of circular Xcode project references.

## 3.0.3 (2025-03-15)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- Rebuilt defective release binary.

## 3.0.2 (2025-03-03)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- Updated XcodeProj dependency provides support for Xcode 16's new project format.
- Fix retain comment commands for imports.

## 3.0.1 (2024-12-28)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- A clean build is no longer required when a file is deleted from the scanned project.

## 3.0.0 (2024-12-27)

##### Breaking

**3.0 is a major breaking change and requires some manual migration, please see the [3.0 Migration Guide](https://github.com/peripheryapp/periphery/wiki/3.0-Migration-Guide).**

- Support for installing via CocoaPods has been removed.
- Removed support for Swift 5.9/Xcode 15.2.
- Periphery is now available directly from Homebrew, and the `peripheryapp/periphery` tap is no longer updated. To migrate run the following:
```
brew remove periphery
brew untap peripheryapp/periphery
brew update
brew install periphery
```

##### Enhancements

- Added support for Swift Testing.

##### Bug Fixes

- Fix numerous issues where generated code could not be scanned.
- Fix support for Xcode's new folder format.
- Fix cloning private Swift package repositories.

## 2.21.2 (2024-11-01)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- Fix parsing of Xcode 16 projects.

## 2.21.1 (2024-09-28)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- Enums with the `@main` attribute are now retained.
- Fixed issue in Swift 6 where declarations that override external type members are incorrectly identified as unused.
- Unused public/exported imports are excluded from the results even if unused in the declaring file as the exported symbols may be referenced in other files, and thus removing the import would result in a build failure.

## 2.21.0 (2024-06-15)

##### Breaking

- Removed support for Swift 5.8/Xcode 14.3.

##### Enhancements

- Added baseline support. Write a baseline with `--write-baseline <file>` and use it with `--baseline <file>`.

##### Bug Fixes

- Fix local Swift package support.

## 2.20.0 (2024-05-29)

##### Breaking

- None.

##### Enhancements

- Added GitHub Actions output formatter.

##### Bug Fixes

- Disable unused import analysis for files retained with `--retain-files`.
- Fix handling of Xcode project paths containing spaces.
- Fix bug causing non-deterministic results for structs with implicit initializers.

## 2.19.0 (2024-05-20)

##### Breaking

- None.

##### Enhancements

- Unused import detection is now enabled by default.
- Added the `--retain-encodable-properties` option to retain all properties on `Encodable` types only.
- Added the `--xcode-list-arguments` option to pass additional arguments to `xcodebuild -list`.
- Added the `--skip-schemes-validation` option to skip validation of Xcode schemes.

##### Bug Fixes

- `@State` and `@Binding` properties are now excluded from assign-only property analysis.
- Unused imports are now detected in files containing no references.

## 2.18.0 (2024-01-21)

##### Breaking

- The command-line parsing strategy for options that were delimited by a pipe or comma has changed. These options are now parsed as a space delimited list, e.g `--option "arg1" "arg2"`.
- The option `--external-encodable-protocols` is deprecated, use `--external-codable-protocols` instead.

##### Enhancements

- Add experimental unused import analysis option `--enable-unused-import-analysis`.
- Add experimental automatic code removal option `--auto-remove`.
- Assign-only properties on structs with synthesized initializers are now detected.
- Added the `--retain-codable-properties` option to retain all properties on Codable types.
- Results for redundant protocol conformances will now list the inherited protocols that should replace the redundant conformance, if any.
- Added the `--retain-files` option to retain all declarations within the given files.

##### Bug Fixes

- Subscript functions required by `@dynamicMemberLookup` are now retained.
- A newline is no longer printed before non-Xcode formatted results.
- `--external-codable-protocols` now retains enums that conform to `CodingKey`.
- Fix public accessibility false-positive for actors.
- Fix public accessibility false-positive for property wrappers.
- Fix public accessibility false-positive for declarations referenced from a public `@inlinable` function.
- Fix public accessibility false-positive for function parameter default values.
- Fix public accessibility false-positive for inherited and default associated types.
- Fix public accessibility false-positive for generic types used in the generic argument clause of a return type.
- Fix public accessibility false-positive for retained/ignored declarations.
- Fix public accessibility false-positive for enum case parameter types.
- Fix public accessibility false-positive for properties initialized with generic specialized types.
- Types associated with assign-only properties are no longer identified as unused until the property is removed.
- Classes referenced in Info.plist as `NSPrincipalClass` and `WKExtensionDelegateClassName` are now retained.

## 2.17.1 (2023-12-04)

##### Breaking

- None.

##### Enhancements

- Add support for indexing plist files via the generic `--file-targets-path` option.

##### Bug Fixes

- None.

## 2.17.0 (2023-11-23)

##### Breaking

- None.

##### Enhancements

- Added the `--relative-results` option to output result paths relative to the current directory.
- `--quiet` now silences warnings too.

##### Bug Fixes

- Fix redundant public accessibility analysis for protocol members declared in extensions that are referenced cross-module where the protocol itself is not.
- Remove checks causing errors when scanning multi-platform projects.
- Additional arguments passed through to xcodebuild/swift are now quoted automatically as needed.

## 2.16.0 (2023-09-27)

##### Breaking

- None.

##### Enhancements

- SwiftUI previews (`PreviewProvider`) are no longer retained by default. Retain them with `--retain-swift-ui-previews`.

##### Bug Fixes

- Fix retaining members of public generic protocol extensions with `--retain-public`.

## 2.15.1 (2023-09-17)

##### Breaking

- None.

##### Enhancements

- Swift 5.9 support.

##### Bug Fixes

- Path forward slashes in JSON output formats are no longer escaped.
- `INDEX_ENABLE_DATA_STORE` is now forcefully enabled as it's required for indexing in some cases.

## 2.15.0 (2023-07-04)

##### Breaking

- Swift 5.7 and macOS 12 are no longer supported.

##### Enhancements

- Reduced indexing and analysis runtime by ~60%.

##### Bug Fixes

- Fix indexing multi-platform projects such as those containing watchOS extensions.
- Subclasses of CLKComplicationPrincipalClass referenced from an Info.plist are now retained.

## 2.14.1 (2023-06-25)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- Revert SwiftPM binary command plugin. Sorry folks, but SwiftPM doesn't provide the appropriate permissions for Periphery to build projects in the sandbox.

## 2.14.0 (2023-06-24)

##### Breaking

- None.

##### Enhancements

- Add the `--retain-objc-annotated` option.
- Added support for SwiftPM binary command plugin.

##### Bug Fixes

- None.

## 2.13.0 (2023-05-14)

##### Breaking

- None.

##### Enhancements

- Improve indexing performance when multiple index stores are provided.
- Added `--external-test-case-classes` option to allow external types to be treated as XCTestCase subclasses.
- Comment commands now support trailing comments, e.g `// periphery:ignore - explanation of why this is necessary`

##### Bug Fixes

- Fix handling of relative paths in `--file-targets-path`.
- Fix redundant public accessibility false positives when `--retain-objc-accessible` is enabled.

## 2.12.3 (2023-03-22)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- Fix index/report exclude regression.

## 2.12.2 (2023-03-19)

##### Breaking

- None.

##### Enhancements

- Significantly improve the performance of index and report filtering.
- Moderate improvements to indexing and analysis performance.

##### Bug Fixes

- `COMPILER_INDEX_STORE_ENABLE` is now forcefully enabled as it's required for indexing.
- Fix false positive where a `typealias` is extended but otherwise unused.
- Fix redundant accessibility analysis for function metatype arguments.
- Fix redundant accessibility analysis for property types inferred from a function call initializer.

## 2.12.1 (2023-03-04)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- Fix JSON deserialization crash caused by unrelated warnings in the output from `xcodebuild -list -json`.
- Retain all `@MainActor` annotated types and their constructors to workaround a bug in Swift 5.7.
- Retain all constructors on types instantiated via `Self(...)` to workaround false positives caused by a bug in Swift.
- `Set<AnyCancellable>` and `NSKeyValueObservation` are now included in the default values for `--retain-assign-only-property-types`.
- Improve accuracy of guard-let shorthand workaround.
- Fix unused parameter false positive result for parameter used within a nested computed variable.

## 2.12.0 (2023-01-13)

##### Breaking

- None.

##### Enhancements

- Add CodeClimate output formatter available via the `--format codeclimate` option.
- Add support for third-party build systems, such as Bazel.

##### Bug Fixes

- Enums that conform to SwiftUI special Provider protocols are now retained, as was already the case for structs and classes.

## 2.11.0 (2023-01-08)

##### Breaking

- None.

##### Enhancements

- Add `clear-cache` command.
- Add support for analyzing local SwiftPM packages in Xcode projects.

##### Bug Fixes

- AnyCancellable properties are now excluded from assign-only property analysis.

## 2.10.3 (2023-01-02)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- Fix retaining CodingKeys enum in a struct whose Codable conformance is declared in an extension.
- Used tagged dependencies to prevent "unsafe build flags" error from SwiftPM.
- Fix old index store use by including Xcode version hash in DerivedData directory name.

## 2.10.2 (2022-11-27)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- Fix guard-let shorthand syntax.
- Fix accuracy of unused parameter analysis for overridden and protocol conforming functions.
- Fix retaining `buildFinalResult(_:)` and `buildLimitedAvailability(_:)` result builder methods.

## 2.10.1 (2022-11-20)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- Fix error building with SwiftPM and Swift 5.7: `the target 'PeripheryKit' in product 'periphery' contains unsafe build flags`
- Fix unused parameter analysis for shorthand if-let syntax.
- Workaround Swift shorthand if-let syntax bug (https://github.com/apple/swift/issues/61509). Global properties are not handled by this workaround.
- Fix retaining inferred associated types.
- Fix redundant public accessibility analysis for types used in closure signatures.
- Conflicting index store units are now detected and result in an error.

## 2.10.0 (2022-10-10)

##### Breaking

- Swift 5.6 or later is now required.

##### Enhancements

- Add `--report-include` option to filter reported violations with an allowlist.
- Support for reading Xcode 14 generated index stores.

##### Bug Fixes

- None.

## 2.9.0 (2022-05-08)

##### Breaking

- Swift 5.5 or later is now required.

##### Enhancements

- Add support for Swift 5.6.
- Output is now line buffered when writing to a fifo/pipe.

##### Bug Fixes

- IBSegueAction annotated functions are now retained.

## 2.8.6 (2022-01-06)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- Fix another crash while indexing.

## 2.8.5 (2022-01-03)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- Fix a crash while indexing.

## 2.8.4 (2021-12-30)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- Fix false positive when protocols requirements are satisfied in another file from the one that declares the conformance.
- Fix redundant public accessibility analysis of enum associated value types.
- Fix redundant public accessibility analysis of aliased types.
- Comment commands can now retain redundant protocols.
- Fix excluding paths that contain relative components, e.g `--report-exclude "../file.swift"`.

## 2.8.3 (2021-11-29)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- Fix false positive when a class inherits a class with the same name from another module.
- Retain parameters on protocol function members implemented by an external type.
- Unused function parameters on unimplemented protocol function members are now retained, as the function may still be referenced from an existential type.
- Fix incorrect redundant public accessibility on a public superclass when a subclass is used in another module.
- Result Builder static methods are now retained.
- Assign-only properties that are assigned multiple times in the same method are now correctly identified as assign-only.
- Fix issue where properties with identical names at different scopes could cause inconsistent results from assign-only property analysis.

## 2.8.2 (2021-11-06)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- The `DEVELOPER_DIR` environment variable is now respected.
- Updated `XcodeProj` dependency resolves building with Xcode 13.

## 2.8.1 (2021-08-01)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- Fix comment ignore command for properties with multiple bindings.

## 2.8.0 (2021-07-23)

##### Breaking

- `--index-exclude` and `--report-exclude` options now accept Bash version 4 glob syntax. Therefore, recursive globs "**" are now supported.

##### Enhancements

- SwiftUI @(UI/NS)ApplicationDelegateAdaptor wrapped properties and now retained.
- All file types can now be excluded from indexing.

##### Bug Fixes

- None.

## 2.7.1 (2021-07-04)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- Fix crash caused by cyclic inherited type references.

## 2.7.0 (2021-06-29)

##### Breaking

- None.

##### Enhancements

- `NSEntityMigrationPolicy` subclasses referenced by `.xcmappingmodel` are now retained.
- `ValueTransformer` subclasses referenced by `.xcdatamodeld` are now retained.
- Properties of types directly or indirectly conforming to `Encodable` are now automatically retained. The `--external-encodable-protocols` option has been added to instruct Periphery that the specified external protocols also inherit `Encodable`.

##### Bug Fixes

- Fix `--index-exclude` resulting in an error about unindexed files.
- Fix an error during guided setup when `xcodebuild` is not setup for command line use.
- `CodingKey` enums of `Encodable` conforming types are now also retained like `Decodable` types.
- Fix detection of assign-only properties when the getter is shadowed by a parameter with the same name.

## 2.6.0 (2021-06-08)

##### Breaking

- Removed support for Swift <= 5.2.

##### Enhancements

- Using an index store that does not contain complete data for the requested targets now results in an error.
- The `--index-store-path` option now implies `--skip-build`.
- Guided setup now omits the `--targets` option from the generated command when 'all' targets are selected for SwiftPM projects.
- Add option to guided setup to save the configuration to '.periphery.yml'.

##### Bug Fixes

- Fix parsing `INFOPLIST_FILE` references containing `$(SRCROOT)`.

## 2.5.2 (2021-06-03)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- Fix erroneous results for explicit 'getter' accessors.

## 2.5.1 (2021-06-02)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- Fix an issue where scans with many schemes could breaking loading of the index store.

## 2.5.0 (2021-05-27)

##### Breaking

- None.

##### Enhancements

- Add redundant public accessibility analysis.
- Add arm64 support.
- Add `--retain-assign-only-property-types` option to retain assign-only properties based on their type.
- Declarations in an entry point file (e.g main.swift) are no longer blindly retained, even if unused.
- Additional arguments passed to xcodebuild can now override the default set of environment based arguments.

##### Bug Fixes

- Fix issue where protocol property references could be incorrectly associated with the getter/setter rather than the property itself, leading to erroneous results.
- Fix unused parameter false positive result for identical function signatures at the same location in different files.

## 2.4.3 (2021-03-05)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- Retain constructors of generic structs that cannot be identified as used due to Swift bug SR-7093.

## 2.4.2 (2021-02-11)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- In Swift 5.3 and lower, all optional protocol members are now retained in order to workaround a Swift bug. This bug is resolved in Swift 5.4.
- Cases of public enums are now also retained when using `--retain-public`.
- Open method parameters are now also retained when using `--retain-public`.
- Empty public protocols that have an implementation in extensions are no longer identified as redundant.
- Foreign protocol method parameters are no longer identified as unused.

## 2.4.1 (2020-12-20)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- Fix ignore comments on protocol declarations.

## 2.4.0 (2020-12-19)

##### Breaking

- The `--xcargs` option has been removed, and superseded by passing arguments following the `--` terminator. E.g `periphery scan --xcargs --foo` is now `periphery scan -- --foo`. This feature can also be used to pass arguments to `swift build` for SwiftPM projects.

##### Enhancements

- None.

##### Bug Fixes

- None.

## 2.3.3 (2020-12-17)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- Improve unused parameter location identification.

## 2.3.2 (2020-12-10)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- Fix indexing failure on unhandled declaration kinds, such as 'commentTag'.
- `--retain-objc-accessible` also retains private declarations explicitly attributed with `@objc`.

## 2.3.1 (2020-12-06)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- Fix crash during indexing phase.

## 2.3.0 (2020-12-05)

##### Breaking

- JSON and CSV output formats have changed to reflect the fact that declarations can have multiple IDs if they're members of multiple build targets.
- Declarations accessible by the Objective-C runtime are no longer retained by default. The `--no-retain-objc-annotated` option has been removed, and `--retain-objc-accessible` added.

##### Enhancements

- Protocols that are never used as an existential type are now explicitly identified as redundant rather than simply unused, which could be confusing.
- Add `--clean-build` flag to clean build artifacts before the build step.
- Add support for files that are members of multiple build targets. Such files no longer produce erroneous results.

##### Bug Fixes

- Protocol members whose implementation is provided by an external type, yet aren't referenced via a value type are now identified as unused.
- @IBInspectable properties are now retained.
- Declarations ignored with a '// periphery:ignore' comment now also retain their references to other declarations.
- Fix running Periphery from within Xcode where Xcode's environment variables could cause build failures or incorrect results.
- Fix an issue where a protocol could incorrectly retain references to methods in an unused conforming declaration.

## 2.2.2 (2020-11-23)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- Extension classes referenced in Info.plist as NSExtensionPrincipalClass are now retained.

## 2.2.1 (2020-11-22)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- Fix unused parameter identification when surrounded with backquotes.

## 2.2.0 (2020-11-21)

##### Breaking

- None.

##### Enhancements

- Add support for SwiftPM & Xcode mixed projects.

##### Bug Fixes

- None.

## 2.1.1 (2020-11-18)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- IBOutlets and IBActions that reside in a base class that are referenced only via a subclass are now retained.

## 2.1.0 (2020-11-14)

##### Breaking

- None.

##### Enhancements

- Added a Checkstyle output formatter.

##### Bug Fixes

- Fix Swift 5.2 support.
- Updated Yams dependency to fix building with Swift for Tensorflow.
- Fix possible concurrent mutation crash.
- Classes & structs that conform to SwiftUI's LibraryContentProvider are now retained.

## 2.0.1 (2020-11-10)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- Fix version number.

## 2.0.0 (2020-11-10)

##### Breaking

- SourceKit based indexing has been removed, the IndexStore indexer is now the sole indexer. Therefore, the following scan options have been removed: `--use-index-store`, `--use-build-log`, `--save-build-log`.
- The `scan-syntax` command has been removed.

##### Enhancements

- Support for code comments to ignore unused declarations.
- Support for analyzing Swift Package Manager projects.
- Linux support for Swift Package Manager projects.
- Assign-only property detection is back and enabled by default. Disable it with `--retain-assign-only-properties`.
- Added `--skip-build` option to skip the build phase.

##### Bug Fixes

- UISceneDelegateClassName & UISceneClassName referenced in Info.plist are now retained.
- Ignore parameters from functions annotated with @IBAction.
- Classes & structs that conform to SwiftUI's PreviewProvider are now retained.
- Support @main entry points.
- Fix unused recursive function detection when using the index store.
- Properties named in struct implicit constructors are now retained.
- Implicit declarations such as struct constructors are now retained.
- A `typealias` that defines an `associatedtype` in an external protocol is now retained.
- All custom `appendInterpolation` methods are now retained, as they cannot be identified as unused due to https://github.com/apple/swift/issues/56189
- Fixed path resolution for nested projects in Xcode workspaces.
- `wrappedValue` and `projectedValue` properties in property wrappers are now retained.
- `XCTestManifests.swift` is now treated as an entry point file like `LinuxMain.swift`.
- Updated `XcodeProj` dependency to resolve some Xcode project parsing issues.

## 1.8.0 (2020-10-3)

##### Breaking

- Aggressive Mode has been removed as it provided little value.
- Removed undocumented diagnosis console feature.

##### Enhancements

- Add Xcode 12 support.

##### Bug Fixes

- Fixed an issue where implicit declarations inserted by SourceKit could cause incorrect results.

## 1.7.1 (2020-04-18)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- Fix --exclude option for scan-syntax.
- Bundle lib_InternalSwiftSyntaxParser.dylib in the release archive.

## 1.7.0 (2020-04-17)

##### Breaking

- None.

##### Enhancements

- Support for Xcode 11.4, Swift 5.2.
- Experimental IndexStore based indexer.

##### Bug Fixes

- Fix shell escaping issues.

## 1.6.0 (2020-03-28)

##### Breaking

- None.

##### Enhancements

- Add support for Xcode 11.3.

##### Bug Fixes

- None.

## 1.5.1 (2019-07-06)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- Fix CocoaPod.

## 1.5.0 (2019-07-06)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- Xcode 10.2 compatibly.

## 1.4.0 (2019-03-02)

##### Breaking

- None.

##### Enhancements

- New `strict` option to exit with non-zero status if any unused code is found.
  [Cihat Gündüz](https://github.com/Dschee)
  [#22](https://github.com/peripheryapp/periphery/issues/22)
  [#23](https://github.com/peripheryapp/periphery/pull/23)

- Add official Homebrew support.
  [Ian Leitch](https://github.com/ileitch)
  [#24](https://github.com/peripheryapp/periphery/pull/24)

##### Bug Fixes

- Fix parsing of projects using Siri message intents.
  [Ian Leitch](https://github.com/ileitch)
  [#25](https://github.com/peripheryapp/periphery/issues/25)
  [#26](https://github.com/peripheryapp/periphery/pull/26)

## 1.3.0 (2019-02-10)

##### Breaking

- First open-source release.

##### Enhancements

- None.

##### Bug Fixes

- None.

## 1.2.3 (2019-01-05)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- Don't attempt to syntax scan directories ending with .swift.
- Detect invalid xcodeproj references.

## 1.2.2 (2018-12-19)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- Fix infinate loop from parsing projects with cyclic references.

## 1.2.1 (2018-12-12)

##### Breaking

- None.

##### Enhancements

- Improve performance of scan-syntax command.

##### Bug Fixes

- Fix parsing of #warning and #error directives.

## 1.2.0 (2018-12-11)

##### Breaking

- None.

##### Enhancements

- Unused function prameter analysis.
- Terminate all child processes on SIGINT.
- Exclude pod schemes from guided setup.
- Remove retain ObjC question from guided setup.

##### Bug Fixes

- Avoid passing 'CURRENT_ARCH' and 'arch' environment variables to xcodebuild when their value is 'undefined_arch'.

## 1.1.3 (2018-11-10)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- Improved target module name identification.

## 1.1.2 (2018-10-31)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- Fix crash when inspecting project configuration for nested .xcodeproj.
- Detect .xcodeproj referenced from within groups in an .xcworkspace.

## 1.1.1 (2018-10-26)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- Projects nested within other projects are now identified.

## 1.1.0 (2018-10-29)

##### Breaking

- None.

##### Enhancements

- Label results identified by aggressive mode.
- Add compiler flags to speed up build phase.
- Schemes are built in the order they're given.
- Add error hint for CocoaPods bug #8000.
- Add support for YAML configuration.

##### Bug Fixes

- Retain XCTestCase classes that do not directly inherit XCTestCase.

## 1.0.0 (2018-10-20)

##### Breaking

- None.

##### Enhancements

- No more trial mode - 100% of results are now free. Advanced features require a Pro license.

##### Bug Fixes

- Fixed issue with poor performance resulting in a segmentation fault.

## 0.12.2 (2018-09-27)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- Ensures Xcode is configured for command-line use.

## 0.12.1 (2018-09-26)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- Built with a static Swift stdlib.
- Ignore xcworkspace generated by Swift Package Manager inside the xcodeproj.

## 0.12.0 (2018-09-24)

##### Breaking

- None.

##### Enhancements

- Support for saving, and using build logs in order to skip the build phase.
- All output format types are now available in trial mode.

##### Bug Fixes

- Unused code with cyclic dependencies is now detected.
- Protocol declarations implemented in a subclass of the conforming class are now identified as used.
- Protocols that inherit a foreign protocol (e.g from Foundation) are now treated differently than other protocols, as Periphery cannot detect declarations that are used internally by the foreign module. For example, if your class conforms to Comparable and implements <(lhs:rhs:), the behavior of sort() may be altered, yet Periphery does not have visibility of any directs call to <(lhs:rhs:).

## 0.11.2 (2018-08-07)

##### Breaking

- None.

##### Enhancements

- --report-exclude and --index-exclude options now expect a pipe character to delimit multiple globs.

##### Bug Fixes

- None.

## 0.11.1 (2018-08-06)

##### Breaking

- None.

##### Enhancements

- Identify LinuxMain.swift as an entry point.

##### Bug Fixes

- Fix regression of handling schemes and targets containing spaces.

## 0.11.0 (2018-08-04)

##### Breaking

- None.

##### Enhancements

- Added tips for eliminating false positives in trial mode.
- Added check-update command.
- Added ability to exclude files either from indexing or final report.

##### Bug Fixes

- None.

## 0.10.0 (2018-07-10)

##### Breaking

- None.

##### Enhancements

- Added support for Xcode 10.
- Warn about source files that are members of multiple targets.
- Diagnosis console now lists active references as their source location.

##### Bug Fixes

- Fixed issue where error messages would not be printed before Periphery exits.

## 0.9.0 (2018-06-22)

##### Breaking

- None.

##### Enhancements

- Added guided setup flow.

##### Bug Fixes

- None.

## 0.8.1 (2018-06-13)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- Handle explicitly defined PRODUCT_MODULE_NAME.

## 0.8.0 (2018-06-12)

##### Breaking

- None.

##### Enhancements

- Added support for Xcode's new build system.
- Added support for analyzing XCTest targets.
- Added interactive diagnosis console, enabled with the --diagnose option.
- Licenses can now be activated using --email and --key options instead of entering them interactively.

##### Bug Fixes

- Improve parsing of xcodebuild -list output.
- Type aliases that define an associated type are now identified as used.

## 0.7.3 (2018-05-11)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- Workaround issue with xcodebuild using non-UTF8 encoding.

## 0.7.2 (2018-05-03)

##### Breaking

- None.

##### Enhancements

- Enable analysis of CocoaPod targets.

##### Bug Fixes

- None.

## 0.7.1 (2018-05-01)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- Improve scheme identification for older workspaces.
- Fix handling of source files containing single quotes.
- Fix handling of paths to swiftc that contain hyphens e.g Xcode-9.3.app.

## 0.7.0 (2018-04-29)

##### Breaking

- None.

##### Enhancements

- Disabled code signing as it's not necessary and can cause build failures.
- Schemes are no longer required to be marked as shared in order to be discovered.

##### Bug Fixes

- Fixed discovery of xibs/storyboards that reside within a Base.jproj.
- Fix retention of protocol declarations with a default implementation within an extension.

## 0.6.2 (2018-04-26)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- Correctly handle projects containing spaces their PRODUCT_NAME.
- Add support for missing declaration kinds.

## 0.6.1 (2018-04-25)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- Improve xcodebuild swiftc argument parsing such that CoreData generated model file arguments are retained.
- Improved invalid scheme error message.

## 0.6.0 (2018-04-21)

##### Breaking

- None.

##### Enhancements

- Added trial mode.

##### Bug Fixes

- None.

## 0.5.0 (2018-04-17)

##### Breaking

- The --retain-all-enum-cases option has been removed. Unused cases of enums that are not raw representable are always identified. Unused cases of raw representable enums are now implicitly used since their use may be completely dynamic. --aggressive analysis disables this implicit behavior.
- The --retain-objc-annotated option is now enabled by default.

##### Enhancements

- Xcode format output is colored to improve readability.

##### Bug Fixes

- CodingKey enums are now correctly identified as used if the enclosing class or struct conforms to Decodable.

## 0.4.0 (2018-04-16)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- Fix retention of declarations marked @IBOutlet or @IBAction.

## 0.3.0 (2018-04-14)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- Fix issue parsing Xcode projects that contained groups without an associated physical directory.

## 0.2.0 (2018-04-09)

##### Breaking

- None.

##### Enhancements

- None.

##### Bug Fixes

- Added --project option for use with projects that do not have an .xcworkspace.

## 0.1.0 (2018-04-07)

- Initial release.
