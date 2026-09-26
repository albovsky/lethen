# Lethen user guide

Lethen finds unused code in Swift projects. This guide covers installation, running a scan for each project type, what each result means and why a declaration is or is not reported, comment commands, baselines, output formats, and continuous integration. It supersedes the [historical upstream guide](UPSTREAM-README.md) for lethen users; that file is kept for reference.

## How a scan works

A scan has four steps. Lethen builds the project with indexing enabled, so the compiler writes an index store describing every declaration and reference. It reads that store together with each Swift source file, plus Interface Builder files, Info.plist files, and Core Data models, into a graph. A series of mutators then adjusts the graph to reflect how Swift really uses code: entry points, test cases, protocol conformances, synthesized code, Objective-C exposure, and so on. Finally it walks the graph from its roots and reports what cannot be reached.

Only code that was compiled is indexed. If a class is referenced only from a file that was not built, lethen reports the class as unused. Make sure every target that contains references is built: for an Xcode project, pick schemes with `--schemes`; for a Swift package, every target is built.

## Installation

macOS release binaries and Homebrew are Apple silicon only. See [Supported platforms](../CONTRIBUTING.md#supported-platforms) for the Intel source-build support window.

On Apple silicon Macs running macOS 15 or later, install the signed and notarized binary with Homebrew:

```sh
brew install albovsky/tap/lethen
lethen version
```

Lethen loads Xcode's indexing library at launch, so Xcode must be installed as `/Applications/Xcode.app` or `/Applications/Xcode-beta.app`, or the Command Line Tools must be installed. Upgrade with `brew upgrade lethen`.

### Download the macOS zip

Download [lethen-3.8.1-macos-arm64.zip](https://github.com/albovsky/lethen/releases/download/3.8.1/lethen-3.8.1-macos-arm64.zip) and [SHA256SUMS](https://github.com/albovsky/lethen/releases/download/3.8.1/SHA256SUMS) into the same directory, then run there:

```sh
shasum -a 256 -c SHA256SUMS
ditto -x -k lethen-3.8.1-macos-arm64.zip lethen-3.8.1
mkdir -p "$HOME/.local/bin"
install -m 755 lethen-3.8.1/lethen "$HOME/.local/bin/lethen"
export PATH="$HOME/.local/bin:$PATH"
lethen version
```

Keep the PATH export in your shell profile.

### Linux

On Linux, releases after 3.8.1 include tarballs for x86_64 and aarch64. They need glibc 2.35 or later and a Swift 6.3 or newer toolchain; the README's Linux section shows how to install one. The tarball's `bin/lethen` uses the indexing library of the `swiftc` on your `PATH`, so swiftly toolchains work. Swift 6.1 and 6.2 cannot load it; use a source build of 3.8.1 with them.

### Build from source

Intel Macs build Lethen from source, and so can any Linux system with a supported toolchain. On macOS, select a full Xcode installation, for example:

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

Then build the tag you want:

```sh
git clone --branch 3.8.1 --depth 1 https://github.com/albovsky/lethen.git
cd lethen
swift build -c release --product lethen
lethen_bin_dir="$(swift build -c release --show-bin-path)"
mkdir -p "$HOME/.local/bin"
install -m 755 "$lethen_bin_dir/lethen" "$HOME/.local/bin/lethen"
export PATH="$HOME/.local/bin:$PATH"
lethen version
```

Add the `export PATH` line to your shell profile. On Linux, build with an official Swift toolchain the same way; Xcode projects are macOS-only, while Swift packages, Bazel, and generic projects work on both platforms.

Lethen supports the current Xcode major and the final release of the previous major, the Swift toolchains they ship, the same Swift minors on Linux through the official containers, and the current and previous Bazel LTS. The README's verified-combinations table records exactly which toolchains and hosts each release was tested on.

## Your first scan

Change to the project directory and run the guided setup:

```sh
lethen scan --setup
```

It detects the project type, asks a few questions (schemes, Objective-C, whether public declarations count as used), offers to save the answers to `.periphery.yml`, prints the full command, and runs it. Guided setup needs an interactive terminal; in CI, pass the options directly.

Without `--setup`, lethen looks for a project in this order: `--project` (Xcode), `--generic-project-config`, `--bazel`, then a `Package.swift` in `--project-root` (the current directory by default).

Arguments after `--` go to the underlying build command. Xcode projects usually need a destination:

```sh
lethen scan --project MyApp.xcodeproj --schemes MyApp -- -destination 'generic/platform=iOS Simulator'
```

## Project types

### Swift packages

A managed scan runs `swift build --build-tests --enable-index-store` and reads the index store from the package's build directory. Managed scans always clean first when products already exist: SwiftPM does not treat indexing as a change that invalidates compiled files, so a build tree produced by a plain `swift build` yields a stale or partial index and silently wrong results. The cost is that **a managed SwiftPM scan is always a full rebuild.**

To keep incremental builds, build the index yourself and point lethen at it:

```sh
swift build --enable-index-store
lethen scan --skip-build --index-store-path "$(swift build --show-bin-path --enable-index-store)/index/store"
```

Use `--skip-build` only with an index you know is current. Packages that only build for iOS or another Apple platform cannot be built by `swift build`; build them with `xcodebuild` and scan the DerivedData index store the same way (see Continuous integration).

### Xcode projects and workspaces

Pass `--project` with the `.xcodeproj` or `.xcworkspace` and `--schemes` with the schemes to build. Lethen runs `xcodebuild build-for-testing` once per scheme into its own DerivedData directory under `~/Library/Caches/com.github.peripheryapp`, keyed by Xcode version, project name, and the set of schemes, so a second scan reuses the build. `--clean-build` deletes that directory first. `lethen clear-cache` removes the whole cache directory.

Interface Builder files, Info.plist files, and Core Data models found in the project are read for class and member references.

### Bazel

`--bazel` queries the workspace for top-level application, test, and library targets, generates a hidden scan rule, and runs it. `--bazel-filter` narrows the default query and `--bazel-query` replaces it. Lethen passes `--check_visibility=false` unless you set `--bazel-check-visibility`, in which case the generated package must be visible to your targets.

The Bazel Central Registry's `periphery` module is upstream Periphery, so add a source override for lethen in `MODULE.bazel`; `lethen scan --setup` prints the snippet for the installed version, and `lethen scan --bazel` warns when the override is missing.

### Other build systems

`--generic-project-config config.json` scans index stores and resource files you list yourself, with no build step:

```json
{
    "indexstores": ["path/to/file.indexstore"],
    "test_targets": ["MyTests"],
    "plists": ["path/to/Info.plist"],
    "xibs": ["path/to/file.xib", "path/to/file.storyboard"],
    "xcdatamodels": ["path/to/file.xcdatamodel"],
    "xcmappingmodels": ["path/to/file.xcmappingmodel"]
}
```

Every key is required (use an empty list). Relative paths are relative to the current directory.

## Configuration file

Every scan option can be persisted in `.periphery.yml` (or `.periphery.yaml`) in the project root, or in the file named by `--config`. Keys are the option names with underscores, and command-line options override the file. Run a scan with `--verbose` to print the effective configuration as YAML you can copy:

```yaml
project: MyApp.xcodeproj
schemes:
  - MyApp
retain_public: false
retain_objc_accessible: true
report_exclude:
  - "**/Generated/*.swift"
```

## What lethen reports

Each result is a declaration (class, struct, enum, protocol, function, property, initializer, typealias, and so on) with one hint. Only the outermost unused declaration is reported: an unused class is one result, not one per member.

### Unused declarations

The declaration cannot be reached from any entry point. Lethen treats the following as used without being asked, because Swift or a framework reaches them without a visible reference:

- `@main`, `@UIApplicationMain`, and `@NSApplicationMain` types, and `main.swift`.
- `XCTestCase` subclasses and their `test` methods, and Swift Testing `@Suite` and `@Test` declarations in files that import `Testing`. Subclasses of a test base class in another module need `--external-test-case-classes`.
- Members that satisfy a protocol requirement from a module that was not scanned (for example `body` on a SwiftUI `View`, `hash(into:)`, or a UIKit delegate method), overrides of external declarations, and extensions of external types.
- Classes, outlets, actions, and inspectable properties connected in a storyboard or XIB, classes named in Info.plist, and Core Data entity classes and migration policies.
- Every case of an enum with a raw value type, since `init(rawValue:)` can produce any of them.
- Property wrapper `wrappedValue` and `projectedValue`, result builder methods, `appendInterpolation`, `subscript(dynamicMember:)`, `App Intents` types, and `LibraryContentProvider` conformers.
- Code generated by macros; `#Preview` bodies are the exception and are reported unless `--retain-swift-ui-previews` is set, because a view used only in a preview is not used by the application.

Declarations exposed to Objective-C are not assumed to be used. If your project mixes Swift and Objective-C, use `--retain-objc-accessible` to retain everything reachable from the Objective-C runtime (`@objc`, `@objcMembers`, and `NSObject` subclasses), or `--retain-objc-annotated` to retain only explicitly annotated declarations. Lethen cannot see references made from Objective-C code, and string-based lookups such as selectors built from strings are invisible to it.

Frameworks and libraries whose public interface is consumed elsewhere need `--retain-public`. To audit a specific `@_spi` group even then, list it with `--no-retain-spi`.

### Unused parameters

A function parameter that the body never reads. For protocol requirements and overridden methods, a parameter is reported only if it is unused in the requirement and in every implementation; `--retain-unused-protocol-func-params` retains the protocol case. Parameters of functions that only call `fatalError` (typically `required init?(coder:)`), of `@IBAction` methods, and of methods whose base declaration lives in another module are not reported.

### Unused imports

An `import` of a module scanned in the same run that the file never uses. Modules outside the scan are never reported, because a module can re-export others with `@_exported`, and neither are `public`, `@testable`, or conditional imports. Mixed Swift and Objective-C targets produce false positives here; disable the analysis with `--disable-unused-import-analysis` or exclude those files from the results, and keep specific modules with `--retain-unused-imported-modules`.

### Assign-only properties

A property that is written but never read:

```swift
var lastError: Error? // assigned, but never used
```

Sometimes that is intentional, for example a strong reference kept alive on purpose. Silence individual properties with a comment command, whole types with `--retain-assign-only-property-types "AnyCancellable" "Set<AnyCancellable>"` (the type must match the declared annotation exactly), or the analysis with `--retain-assign-only-properties`.

Properties read only by synthesized code are handled in two ways. Synthesized `Equatable` and `Hashable` reads are modeled automatically when a value reaches a comparison, generic code, or an unindexed call; `--retain-equatable-properties` and `--retain-hashable-properties` retain every such property instead. Synthesized `Codable` reads are not modeled: use `--retain-codable-properties` or `--retain-encodable-properties`, and name protocols from other modules that inherit `Codable` with `--external-codable-protocols` and `--external-encodable-protocols`.

### Redundant public accessibility

A `public` declaration that no other module references. Removing `public` shrinks the module's surface and lets whole-module optimization infer `final`. `open` declarations and members of types that are themselves correctly public are not reported. Disable with `--disable-redundant-public-analysis`; `--retain-public` also disables it.

### Redundant protocols

A protocol that types conform to but that is never used as a type: never an existential, a generic constraint, or an inherited protocol. The conformances are reported alongside it so both can be removed.

### Superfluous ignore comments

A `// periphery:ignore` comment on a declaration that is actually used. Turn off with `--no-superfluous-ignore-comments`.

## Comment commands

Place a command on the line above a declaration. It applies to the declaration and everything nested in it.

```swift
// periphery:ignore
class KeptForReflection {}

// periphery:ignore:parameters unusedOne,unusedTwo
func handle(used: String, unusedOne: String, unusedTwo: String) {}

// periphery:ignore - explanation after a hyphen is allowed
var debugOnly = 0
```

`// periphery:ignore:all` at the top of a file, above any code including imports, ignores the whole file; `--retain-files "**/Generated/*.swift"` does the same from the command line.

For generated code, report a result at a more meaningful place with `// periphery:override kind="MyThing" location="path/to/file.swift:42:1"`; a relative location is resolved against the project root.

## Excluding files

- `--exclude-targets` and `--exclude-tests` leave whole targets out of the index; lethen behaves as if their files did not exist, so references inside them do not count.
- `--index-exclude` does the same for file globs. The default excludes build directories and package checkouts.
- `--report-exclude` and `--report-include` only filter what is printed; the files are still indexed. Include wins over exclude.

Globs are Bash-style, relative to the project directory, and several can be given: `--report-exclude "Sources/Single.swift" "**/*.{xib,storyboard}"`.

## Baselines

Adopting lethen on an existing codebase usually starts with many findings. Record them once, then report only new ones:

```sh
lethen scan --write-baseline baseline.json
lethen scan --baseline baseline.json --strict
```

Entries are keyed by the declaration's symbol identifier, so a baselined result survives moving code between files but not renaming the declaration, changing its signature, or moving it to another type or module. Unused-import entries are keyed by file and line and do reappear when lines move. Writing a baseline while one is in use merges the two, so entries for deleted code are never dropped; regenerate the file from scratch now and then. Results hidden by `--report-exclude` are not recorded.

## Output formats and continuous integration

`--format` selects one of `xcode` (default, readable and Xcode-parseable), `json`, `csv`, `checkstyle`, `codeclimate`, `github-actions`, `github-markdown`, and `gitlab-codequality`. `--write-results path` writes the output to a file as well. `--relative-results` prints paths relative to the current directory and is required by `github-actions`. `--quiet` suppresses progress, and `--strict` makes the exit status 1 when anything is reported.

The JSON format includes each declaration's kind, name, modules, modifiers, attributes, accessibility, symbol identifiers, hints, and location.

### Reusing a build in CI

If the pipeline has already built the project, skip lethen's build and scan the existing index store:

- Xcode: `~/Library/Developer/Xcode/DerivedData/<Project>-<hash>/Index.noindex/DataStore`, or wherever `-derivedDataPath` pointed.
- Swift packages: `$(swift build --show-bin-path)/index/store` after a build with `--enable-index-store`.

```sh
lethen scan --skip-build --index-store-path "$DERIVED_DATA/Index.noindex/DataStore" --format github-actions --relative-results --baseline baseline.json --strict
```

### GitHub Actions

```yaml
- name: Scan for unused code
  run: |
    lethen scan --format github-actions --relative-results --baseline baseline.json --strict --disable-update-check
```

Annotations appear on the pull request's changed lines. Pass `--disable-update-check` in CI; the optional update check otherwise contacts GitHub's releases API once per scan and can be disabled permanently with `disable_update_check: true` in the configuration file.

### GitLab

Use `--format gitlab-codequality --write-results gl-code-quality-report.json` and publish the file as a `codequality` report artifact.

### Xcode integration

Get the scan working in a terminal first. Then add an Aggregate target, give it a Run Script build phase containing the same command with the absolute path to `lethen` and `--format xcode`, and set `ENABLE_USER_SCRIPT_SANDBOXING` to `No` for that target, because the sandbox blocks access to the index store and sources. Mark the scheme as shared so the team gets it.

## Troubleshooting

**Wrong results in some files.** The index store can become stale, for example after a scan was interrupted. Run with `--clean-build`.

**Code used only under `#if` is reported.** Only the compiled branch is indexed. Ignore those declarations with a comment command, filter them from the results, or scan once per configuration (`-- -configuration Release`) and combine the reports.

**A local package's public API is reported.** Consumers outside the scanned scheme, such as the package's own test target, are not part of the scan. Scan the package separately or use `--retain-public` for it.

**Mixed Objective-C.** See the Objective-C options above; references from Objective-C into Swift are not visible.

**Index store not found.** For managed SwiftPM scans lethen resolves the active build directory itself. For `--skip-build`, pass `--index-store-path` explicitly and make sure the build enabled indexing.

Known Swift index-store bugs that can produce wrong results are listed in the [historical upstream guide](UPSTREAM-README.md#known-bugs).

## Compatibility with Periphery

Lethen is an independent fork of Periphery 3.8.0. Existing `.periphery.yml` files, `// periphery:` comment commands, the `PeripheryKit` library, and the `periphery` Bazel module keep working. The executable is `lethen`; substitute it for `periphery` in any command you carry over.
