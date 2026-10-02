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

Download [lethen-3.10.0-macos-arm64.zip](https://github.com/albovsky/lethen/releases/download/3.10.0/lethen-3.10.0-macos-arm64.zip) and [SHA256SUMS](https://github.com/albovsky/lethen/releases/download/3.10.0/SHA256SUMS) into the same directory, then run there:

```sh
shasum -a 256 -c SHA256SUMS
ditto -x -k lethen-3.10.0-macos-arm64.zip lethen-3.10.0
mkdir -p "$HOME/.local/bin"
install -m 755 lethen-3.10.0/lethen "$HOME/.local/bin/lethen"
export PATH="$HOME/.local/bin:$PATH"
lethen version
```

Keep the PATH export in your shell profile.

### Mint

[Mint](https://github.com/yonaskolb/Mint) builds Lethen from source at a release tag, which takes a few minutes and needs Xcode (or the Command Line Tools):

```sh
mint install albovsky/lethen@3.10.0
mint run albovsky/lethen@3.10.0 scan
```

To pin it for a project, add `albovsky/lethen@3.10.0` to your `Mintfile`.

### Linux

On Linux, releases from 3.9.0 include tarballs for x86_64 and aarch64. They need glibc 2.35 or later and a Swift 6.3 or newer toolchain; the README's Linux section shows how to install one. The tarball's `bin/lethen` uses the indexing library of the `swiftc` on your `PATH`, so swiftly toolchains work. Swift 6.1 and 6.2 cannot load it; use a source build of 3.8.1 with them.

### Build from source

Intel Macs build Lethen from source, and so can any Linux system with a supported toolchain. On macOS, select a full Xcode installation, for example:

```sh
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

Then build the tag you want:

```sh
git clone --branch 3.10.0 --depth 1 https://github.com/albovsky/lethen.git
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

It detects the project type, asks a few questions (schemes, Objective-C, whether public declarations count as used), offers to save the answers to `.periphery.yml`, prints the full command, and runs it. It skips a question the project already answers: a Swift package whose products are all libraries keeps its public declarations (`--retain-public`), one whose products are all executables reports them, and passing `--retain-public` settles the question too. For Bazel it saves `bazel: true`, so `lethen scan` alone selects Bazel afterwards.

Guided setup asks its questions only on an interactive terminal. When standard input is not one, as in CI or a script, it prints each detected project with the command to run and exits with an error instead of scanning:

```
* Detected Swift Package project
* Assuming all 'public' declarations are in use (--retain-public): the package's products are libraries, which other code imports
* Command to run:
lethen scan --retain-public
```

Values only you can choose, such as an Xcode scheme, appear as placeholders like `<scheme>`. In CI, pass the options directly.

Without `--setup`, lethen looks for a project in this order: `--project` (Xcode), `--generic-project-config`, `--bazel`, then what it finds in `--project-root` (the current directory by default): a `Package.swift`, otherwise a single `.xcworkspace` or `.xcodeproj` directly inside it, otherwise a `MODULE.bazel`. Projects in subdirectories, such as `Pods` and example projects, are never picked, and a workspace is preferred over the projects it references. When several candidates remain, or a `MODULE.bazel` sits beside an Xcode project, lethen stops and lists the `--project` or `--bazel` option to pass.

Arguments after `--` go to the underlying build command. Xcode projects usually need a destination:

```sh
lethen scan --project MyApp.xcodeproj --schemes MyApp -- -destination 'generic/platform=iOS Simulator'
```

## Project types

### Swift packages

A managed scan runs `swift build --build-tests --enable-index-store` and reads the index store from the package's build directory. SwiftPM does not treat indexing as a change that invalidates compiled files, and incremental builds do not always recompile a module that imports a changed module, so an existing build tree can hold a stale or partial index. Lethen therefore reuses the tree only when it can verify it:

- Each verified build ends with a stamp that records the Swift version and the build arguments.
- Before the next build, every module with an object compiled after the stamp (for example by a plain `swift build`), a source edited after it, or a source without an index unit is recompiled, together with every module that imports it.
- After the build, every package source must have a unit for its module, and nothing may remain indexed for a file the package no longer builds.
- A target that `swift build --build-tests` never compiles, such as an executable used only by a command plugin, has neither units nor objects. Lethen records it in the stamp, reuses the tree while it still has no objects, and warns that it is not scanned; pass `--retain-public-targets` for the modules it depends on to keep their public declarations. A target with objects but no units, or a recorded one that gains objects or units, cleans.
- Anything that cannot be verified, including a missing stamp, different build arguments, or a different Swift version, cleans and rebuilds.

A rescan with nothing changed rebuilds nothing; an edit costs the edited module and its importers, never the package's dependencies. `--clean-build` always cleans first. `--verbose` logs which modules were recompiled, or why the build was cleaned.

To build the index yourself instead, point lethen at it:

```sh
swift build --enable-index-store
lethen scan --skip-build --index-store-path "$(swift build --show-bin-path --enable-index-store)/index/store"
```

With `--skip-build` and no `--index-store-path`, lethen reads the package's build directory and stops with a "stale" error when a source file is newer than every index unit for it. An explicit `--index-store-path` is used as-is, so use it only with an index you know is current. Packages that only build for iOS or another Apple platform cannot be built by `swift build`; build them with `xcodebuild` and scan the DerivedData index store the same way (see Continuous integration).

Code inside `#if DEBUG` or its `#else` is compiled in only one configuration, so a function called only in release builds looks unused in a debug scan. `--configurations debug release` (`configurations: [debug, release]` in the configuration file) builds each configuration with `-c` and scans their index stores together: a reference found in either counts. A configuration that fails to build fails the scan. Do not also pass `-c` or `--configuration` in the build arguments. The configurations share one build tree, so each such scan usually rebuilds both from clean instead of reusing the previous build. Xcode projects accept `--configurations` too; see below.

### Xcode projects and workspaces

Pass `--project` with the `.xcodeproj` or `.xcworkspace` and `--schemes` with the schemes to build. Without `--schemes`, Lethen builds the project's only shared scheme and says so; when the project shares several schemes, or none, it stops and lists the schemes to pass. Lethen runs `xcodebuild build-for-testing` once per scheme into its own DerivedData directory under `~/Library/Caches/com.github.peripheryapp`, keyed by Xcode version, project name, and the set of schemes, and also by the configuration and the build arguments when either is given, so a second scan with the same options reuses the build. `--clean-build` deletes that directory first. `lethen clear-cache` removes the whole cache directory.

Interface Builder files, Info.plist files, and Core Data models found in the project are read for class and member references.

`--skip-build` without `--index-store-path` scans without running `xcodebuild` builds. Lethen uses the most recently written of two indexes: its own from an earlier scan, or the one Xcode keeps for this project in its DerivedData (`~/Library/Developer/Xcode/DerivedData`, or the custom location set in Xcode's preferences, matched by the project path Xcode records there). It names the index it chose. Because this index may predate your edits, lethen checks it first: index units older than their source file are ignored, and if a source file has no unit as new as the file, the scan stops with a "stale" error that lists the files. Build in Xcode, or scan without `--skip-build`, to refresh it. Source files that Xcode never indexed are not detected, so build the schemes you scan at least once.

#### Code compiled out by your test configuration

`xcodebuild build-for-testing` builds the configuration of the scheme's Test action, usually Debug, so code compiled only in another configuration, such as the `#else` of `#if DEBUG`, looks unused. Each build line names the configuration it compiles, such as `Building Wikipedia with configuration Test`, read from the scheme file. When the scheme's Test action uses a different configuration from its Run action and no configuration is chosen, Lethen warns that code compiled only in the Run configuration is reported as unused and prints the `--configurations` flag that scans both. Schemes Xcode generates without a file name no configuration and never warn. `--configurations Debug Release` (`configurations: [Debug, Release]` in the configuration file) runs `build-for-testing -configuration <name>` for each listed configuration, each into its own DerivedData directory, and scans their index stores together: a reference found in any of them counts. The names must be build configurations of the project, and the build arguments must not also pass `-configuration`. Each configuration is built for testing so test targets stay in the scan; a configuration without testability, typically Release, fails when a test target uses `@testable import`. That failure fails the scan with xcodebuild's error. Pass `ENABLE_TESTABILITY=YES` after `--`, or list the configurations your app and tests actually use.

`--skip-build --configurations Debug Release` scans without building. It reads the index of Lethen's last completed build of each listed configuration in an earlier `--configurations` scan of the same schemes with the same build arguments, and checks every one of them as described above: a source file edited after any one configuration's index was written stops the scan with a stale-index error, even when another configuration's index is current. A configuration whose last Lethen build did not complete, or that Lethen never built, fails the scan and is named, so scan once without `--skip-build` first. Xcode's own DerivedData index holds whichever configuration Xcode built last, so it is never used for `--configurations`. With `--index-store-path`, pass each configuration's store; explicit stores are read as given.

### Swift package plugin and Xcode command

Lethen's package includes a command plugin, `LethenPlugin`. Add the package with a **branch or commit rule**, not a version: Lethen depends on swift-index-store by commit because that package uses unsafe build flags, and SwiftPM only lets packages with such dependencies be used by branch or commit. In `Package.swift`:

```swift
.package(url: "https://github.com/albovsky/lethen", branch: "master"),
```

In Xcode, choose File > Add Package Dependencies, enter the URL, and pick the Branch or Commit rule.

For a package, run the plugin from the package directory. It takes `lethen scan` options, and build arguments after `--`:

```sh
swift package --allow-writing-to-package-directory --allow-network-connections all lethen
swift package --allow-writing-to-package-directory --allow-network-connections all lethen --format json -- -c release
```

The plugin builds the package with indexing in `.build/lethen`, separately from `.build`, which SwiftPM keeps locked while a plugin runs. It needs to write there and to fetch the package's dependencies for that build, which the two permissions allow; `swift package --disable-sandbox lethen` also works. The first run builds Lethen itself and the package's dependencies, which takes a few minutes; later runs reuse both.

For an Xcode project, right-click the project in the navigator and choose **lethen**. The command scans the index Xcode keeps for the project instead of building, the same way `--skip-build` does, so build the project in Xcode first; results appear as warnings in the Issue navigator. It passes the project's name as the scheme; pass `--schemes` in the command's arguments to choose others.

### Bazel

`--bazel` queries the workspace for top-level application, test, and library targets, generates a hidden scan rule, and runs it. The rule and the scan configuration are written to `lethen_generated` in the workspace's output base (`bazel info output_base`), a directory only you can write to. `--bazel-filter` narrows the default query and `--bazel-query` replaces it. Lethen passes `--check_visibility=false` unless you set `--bazel-check-visibility`, in which case the generated package must be visible to your targets.

The Bazel Central Registry's `periphery` module is upstream Periphery, so add a source override for lethen in `MODULE.bazel`; `lethen scan --setup` prints the snippet for the installed version, and `lethen scan --bazel` warns when the override is missing.

A Bazel scan always builds: the generated scan target indexes your targets and runs the scan, so `--skip-build` and `--index-store-path` stop a Bazel scan with an error. To scan an index store Bazel already wrote, describe the project with `--generic-project-config` (see Other build systems) and list the store there or pass it with `--index-store-path`.

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

Every scan option can be persisted in `.periphery.yml` (or `.periphery.yaml`) in the project root, or in the file named by `--config`. Keys are the option names with underscores, and command-line options override the file. Run a scan with `--verbose` to print the effective configuration as YAML you can copy; verbose output goes to standard error, so redirect it with `2>`:

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

Every result also has a confidence. It is `likely` when a dynamic feature could reach the declaration without a reference Lethen can see: the declaration is accessible from Objective-C, neither `--retain-objc-accessible` nor `--retain-objc-annotated` is set, and the scan could not read every Objective-C file (some C or Objective-C implementation files of the built targets have no index unit, which the scan warns about; with `--skip-build` or `--index-store-path` a target with no units at all counts as unindexed too, because a store Lethen did not build can be partial; or the project kind cannot list its files: generic project configs and Bazel); when Lethen has read every Objective-C file it has seen every reference from them, and the declaration is `certain` unless another rule applies. It is also `likely` when it is a type, method, property, or enum case whose name (without argument labels) appears in a string literal shaped like a symbol reference anywhere in the scanned Swift, C, or Objective-C sources, including the name in an `@selector(...)` expression: a selector such as `"handleTap:"`, a name such as `"MyApp.Store"` for `NSClassFromString`, or a key path such as `"user.name"`. Literals with spaces or interpolation, such as log messages, do not count, and parameters and imports are never `likely` for this reason. It is also `likely` when its name (a type, method, property, enum case, type alias, or operator) is used in a `#if` clause this build did not compile, in the same module: the compiler records nothing for a skipped branch, so a method called only under `#if os(Windows)` looks unused on Linux. Lethen reads which clause compiled from the index, not from the condition, and a member or enum case needs a use spelled as a member access or a call, so a name that is only declared there, or a bare local with the same name, does not count. An enum case matched in a pattern (`case .windowsOnly:`) is not constructed, so it does not count either. Otherwise it is `certain`. Confidence never changes what a baseline filters, and it changes what is reported only under `--min-confidence certain` (see [continuous integration](#output-formats-and-continuous-integration)); results are listed with `certain` ones first, in location order within each tier.

The default `xcode` format ends with a summary on standard error, such as ``3 results, 1 likely. `lethen explain <name>` shows why; `--write-baseline baseline.json` records these so the next scan reports only new ones.`` The baseline hint is left out when `--baseline` or `--write-baseline` is given, `--quiet` suppresses the line, and other formats never print it. `--verbose` adds each result's reason, the sentence JSON gives as `reason`, as an indented line under it:

```
Sources/Store.swift:12:10: warning: Unused function 'reload()'
    reason: no references in the scanned modules
```

### Unused declarations

The declaration cannot be reached from any entry point. Lethen treats the following as used without being asked, because Swift or a framework reaches them without a visible reference:

- `@main`, `@UIApplicationMain`, and `@NSApplicationMain` types, and `main.swift`.
- `XCTestCase` subclasses and their `test` methods, and Swift Testing `@Suite` and `@Test` declarations in files that import `Testing`. Subclasses of a test base class in another module need `--external-test-case-classes`.
- Members that satisfy a protocol requirement from a module that was not scanned (for example `body` on a SwiftUI `View`, `hash(into:)`, or a UIKit delegate method), overrides of external declarations, and extensions of external types.
- Classes, outlets, actions, and inspectable properties connected in a storyboard or XIB, classes named in Info.plist (principal, scene, scene delegate, extension, complication, watch extension delegate, and document classes), and Core Data entity classes and migration policies.
- Every case of an enum with a raw value type, since `init(rawValue:)` can produce any of them.
- Property wrapper `wrappedValue` and `projectedValue`, and their `init(wrappedValue:…)` and `init(projectedValue:)` initializers, every `build…` method of the result builder protocol whatever its labels or arity (including `buildPartialBlock`), `appendInterpolation`, `subscript(dynamicMember:)`, `App Intents` types, and `LibraryContentProvider` conformers.
- Code generated by macros, through the declaration it was generated for: a generated member or conformance counts as used only when that declaration is used, so a type whose only user is its own macro expansion (such as an unused `@Observable` class) is reported; `#Preview` bodies are the exception and are reported unless `--retain-swift-ui-previews` is set, because a view used only in a preview is not used by the application.

Declarations exposed to Objective-C are not assumed to be used. If your project mixes Swift and Objective-C, use `--retain-objc-accessible` to retain everything reachable from the Objective-C runtime (`@objc`, `@objcMembers`, and `NSObject` subclasses), or `--retain-objc-annotated` to retain only explicitly annotated declarations. Lethen reads the index clang writes for Objective-C files in the scanned targets, so a declaration that Objective-C code calls, allocates, or names in a header is used, and `lethen explain` names that line. `@class` forward declarations do not count, and string-based lookups such as selectors built from strings and key-value coding are invisible to it. A name that appears in such a string or `@selector(...)` in an Objective-C file keeps the declaration at `likely` confidence, under its Swift name or the name given by `@objc(name)`.

Frameworks and libraries whose public interface is consumed elsewhere need `--retain-public`. To audit a specific `@_spi` group even then, list it with `--no-retain-spi`. When only some modules have consumers outside the scan, such as a local package whose tests or other clients are not built by the scanned scheme, `--retain-public-targets <module>…` (`retain_public_targets` in the configuration file) retains the `public` and `open` declarations of just those modules and never reports them as redundantly public. A Swift package scan with `--exclude-tests` or `--exclude-targets` warns when an excluded target depends on a scanned one, and names the modules to pass.

### Unused parameters

A function parameter that the body never reads. For protocol requirements and overridden methods, a parameter is reported only if it is unused in the requirement and in every implementation; `--retain-unused-protocol-func-params` retains the protocol case. Parameters of functions that only call `fatalError` (typically `required init?(coder:)`), of `@IBAction` methods, and of methods whose base declaration lives in another module are not reported.

Subscripts are analyzed like functions, and so are closures stored in a property or global (`let transform: (Int, Int) -> Int = { value, unused in value }`), whose unused parameters should become `_`. Closures in local variables and enum case payloads are not analyzed.

### Unused imports

An `import` of a module scanned in the same run that the file never uses. Modules outside the scan are never reported, because a module can re-export others with `@_exported`, and neither are `public`, `@testable`, or conditional imports.

An `@import` in a C or Objective-C file is reported when the file, and the headers it includes, uses no symbol of that module or submodule, nor of a module it depends on, as clang's index shows. The finding names the import as written, such as `MyFramework.Logging`. A symbol counts through any submodule the umbrella header may have brought it from, and a module counts as used when the file uses a symbol of a module it depends on, because it may re-export that module. `#import` and `#include` lines are not considered, only `@import`. A module is checked only when the scan indexed its Swift code, and system modules a module re-exports are not considered. A module the index holds no module unit for, as in a SwiftPM build, is never reported.

Disable the analysis with `--disable-unused-import-analysis` or exclude files from the results, and keep specific modules with `--retain-unused-imported-modules`. A `// periphery:ignore` comment on the line of an `@import`, or the line above it, keeps it.

### Assign-only properties

A property that is written but never read:

```swift
var lastError: Error? // assigned, but never used
```

Sometimes that is intentional, for example a strong reference kept alive on purpose. Silence individual properties with a comment command, whole types with `--retain-assign-only-property-types "AnyCancellable" "Set<AnyCancellable>"` (the type must match the declared annotation exactly), or the analysis with `--retain-assign-only-properties`.

Properties read only by synthesized code are handled in two ways. Synthesized `Equatable` and `Hashable` reads are modeled automatically when a value reaches a comparison, generic code, or an unindexed call; `--retain-equatable-properties` and `--retain-hashable-properties` retain every such property instead. Synthesized `Encodable` reads are modeled the same way: a struct without its own `encode(to:)` has every stored property read, recursively through the structs it stores, wherever a value of it is passed to a function whose parameter is constrained to `Encodable` or is `any Encodable`: `JSONEncoder().encode(_:)` and `PropertyListEncoder().encode(_:)`, an encoding container's `encode` methods, or a function of your own such as `func submit<E: Encodable>(_ event: E)`. Passing it anywhere else, such as to `Array.append(_:)`, `print(_:)`, or a function that takes the concrete type, is not such evidence. Synthesized `Decodable` reads are modeled the same way, for a struct without its own `init(from:)`: wherever the type's metatype, `Type.self`, is passed for a parameter of type `T.Type` (or `[T].Type`) where `T` is constrained to `Decodable` in the function's generic or `where` clause, or of type `any Decodable.Type`, in a function or initializer of your own such as `func load<T: Decodable>(_: T.Type)`, or to the standard decoding calls `JSONDecoder.decode(_:from:)`, `PropertyListDecoder.decode(_:from:)` and the decoding containers' `decode` and `decodeIfPresent`. Its non-optional stored properties without an initial `let` value then count as read, recursively through the structs it stores, because the synthesized initializer requires them and removing one relaxes the shape it validates. `Page<Model>.self` decodes `Model` too when `Page` stores a value of its generic parameter in a decoded property (`items: [Value]`), but not for a phantom parameter or one that `Page` stores only inside another generic wrapper such as `Phantom<Value>` (a limit: the declared type must be `Value` or reach it through only the standard containers, `Optional`, `Array`, `Set`, `Dictionary` and `ContiguousArray`, however nested or spelled, such as `[Value?]` or `[String: [Value]]`), and `Optional<Model>.self`, `Array<Model>.self` and `[String: Model].self` decode `Model`, as does a qualified argument such as `Page<Namespace.Model>.self` (a generic wrapper of the scan, such as `Box<T>`, passes the argument when it stores its own matching parameter, without checking that the wrapper is itself decoded synthesized; a `typealias CodingKeys` whose target is outside the scan cannot be inspected, so every eligible property is treated as decoded and no omitted-key report is possible; a generic typealias of a type, such as `Payload<T> = Page<T>`, passes every argument through without checking that the target stores it; an `init(from:)` or `encode(to:)` whose parameter type is a typealias to `Decoder` or `Encoder` declared in an unscanned module is treated as an unrelated overload, so such a type may be modeled as synthesized and its properties retained) (a qualified generic stored type such as `Namespace.Phantom<Model>` is judged like `Phantom<Model>`); a property with a getter, setter or `_read`/`_modify` body is computed and never coded, whatever its body references (a stored property with `willSet` or `didSet` is still coded), and top-level code in a `main.swift` counts. A user-defined generic type spelled like a standard container (for example `Namespace.Array<Model>`) is treated as that container when specialization arguments are recorded, so its argument is followed directly. Wrapper declarations are matched by base name, so two same-named generic wrappers in different scopes can make a phantom wrapper look like it stores its parameter. Both only over-retain. Only that argument counts: other arguments of the same call, values of a `Decodable` type, wrappers such as `Box<T>`, constraints on a dependent member such as `T.Payload`, typealiases of `Decodable`, and external functions other than the standard decoding calls are not evidence. The same rule applies to a stored property of a generic type, such as `let value: Phantom<Model>`: `Model` is decoded only when `Phantom` stores it. Optional properties, which are decoded with `decodeIfPresent`, stay reported (the types they hold are still decoded, so their required properties are read), as do lazy properties and computed properties, and when the type declares a `CodingKeys` enum, or a `typealias CodingKeys` of one (followed through chains of aliases), only the properties it names are modeled (a `CodingKeys` that cannot be resolved turns the modeling off for that type). A custom `init(from: Decoder)` turns the modeling off, including one that spells the parameter with a typealias of `Decoder` (the alias is looked up by scope, the enclosing type first, or in the named type for a qualified spelling such as `Namespace.Alias`, and followed through chains; two aliases at one level count as the coder; an alias that cannot be resolved counts as the coder, and an alias of another type such as `typealias Number = Int` does not); an unrelated overload such as `init(from number: Int)` does not (nor does `encode(to:)` with a non-`Encoder` parameter for encoding). Classes and enums, and a type that reaches a decoder only through an inferred result or closure type, are not modeled. `--retain-codable-properties` and `--retain-encodable-properties` retain every such property instead, and protocols from other modules that inherit `Codable` are named with `--external-codable-protocols` and `--external-encodable-protocols`.

### Redundant public accessibility

A `public` declaration that no other module references. Removing `public` shrinks the module's surface and lets whole-module optimization infer `final`. `open` declarations and members of types that are themselves correctly public are not reported. Disable with `--disable-redundant-public-analysis`; `--retain-public` also disables it.

### Redundant protocols

A protocol that types conform to but that is never used as a type: never an existential, a generic constraint, or an inherited protocol. The conformances are reported alongside it so both can be removed.

### Unconstructed enum cases

An enum case that is only ever matched, in `switch` cases, `if case`, `guard case`, or `for case`, and never created is dead together with the arms that match it: `Enum case 'x' is matched but never constructed` (hint `unconstructedEnumCase`). Comparisons such as `value == .x` create the case, so they count as construction. Enums whose cases can be created without naming them are skipped: raw-value enums (`init(rawValue:)`), `CaseIterable`, `Decodable` and `Codable` enums, `@objc` enums, public enums under `--retain-public`, and enums a comment command retains or ignores.

### Superfluous ignore comments

A `// periphery:ignore` comment on a declaration that is actually used. Turn off with `--no-superfluous-ignore-comments`.

## Explaining a result

`lethen explain <name>` scans exactly as `lethen scan` does, with the same options, then explains one declaration instead of listing results. The name can carry argument labels or not (`load` or `load(from:)`), be qualified by enclosing declarations and a module (`Store.load`, `App.Store.load`), or be a USR as printed by `--format json`. Every matching declaration is explained:

- **Reported as unused:** whether anything references it at all, or which unused declarations are the only ones that do.
- **Used:** the shortest chain of references from a retained declaration, or from top-level code, to it.
- **Retained:** the rule that retained it, such as `XCTestRetainer`, `PubliclyAccessibleRetainer` with `--retain-public`, or an ignore comment.
- **Not reported:** the comment command that ignores it, or the enclosing declaration that is reported instead.
- **Confidence:** for every reported declaration, `Confidence: certain.` or `Confidence: likely` with the reason, such as a name that appears in a string literal.

```sh
lethen explain functionWithSimpleReturnType
lethen explain Store.load --project MyApp.xcodeproj --schemes MyApp
```

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

`--min-confidence certain` reports only `certain` results; the default, `likely`, reports everything. The filter runs after `--baseline` and before `--report-include` and `--report-exclude`, so it also decides what `--strict` counts and what `--write-baseline` records: a baseline written under `--min-confidence certain` leaves `likely` results out, and they reappear in a later scan without the option. A line on standard error, such as `--min-confidence certain hid 3 results.`, says how many results it hid, and in the `xcode` format the summary line carries it instead; `--quiet` suppresses it. Set it in the configuration file with `min_confidence: certain`. This is the shape for a CI gate that fails only on results Lethen is sure about:

```sh
lethen scan --min-confidence certain --strict
```

`--stats` prints a report after the scan: the time spent in each phase (setup, build, index (planning which source files to read from the index store, then its two Swift passes), analysis, building the results, and output), the number of Swift source files indexed, their lines of code (blank and comment-only lines excluded), the declarations indexed, and indexing plus analysis throughput in lines per second. The report goes to standard error even with `--quiet`, so `json`, `csv`, and the other formats on standard output stay machine-readable. Lines are counted only when `--stats` is given, so other scans do not pay for it. Use it with a managed SwiftPM scan to see the cost of its clean build, or with `--skip-build` to time indexing and analysis alone.

The JSON format includes each declaration's kind, name, modules, modifiers, attributes, accessibility, symbol identifiers, hints, and location, a `confidence` of `certain` or `likely`, a `confidenceReason` that says why a result is `likely` (`null` for `certain` results), and a one-sentence `reason` such as `no references in the scanned modules` or `assigned but never read`; the CSV format ends with a `Confidence` column. Results are sorted with `certain` first. The `xcode`, `github-actions`, `github-markdown`, `gitlab-codequality`, and `codeclimate` formats append `[likely: <why>]` to `likely` results.

### Reusing a build in CI

If the pipeline has already built the project, skip lethen's build and scan the existing index store:

- Xcode: `~/Library/Developer/Xcode/DerivedData/<Project>-<hash>/Index.noindex/DataStore`, or wherever `-derivedDataPath` pointed.
- Swift packages: `$(swift build --show-bin-path)/index/store` after a build with `--enable-index-store`.

```sh
lethen scan --skip-build --index-store-path "$DERIVED_DATA/Index.noindex/DataStore" --format github-actions --relative-results --baseline baseline.json --strict
```

### GitHub Actions

The repository is also a GitHub Action. It installs the release binary for the runner, verifies it against the release's `SHA256SUMS`, caches it in the runner's tool cache, and runs the scan with annotations on the pull request's changed lines:

```yaml
- uses: actions/checkout@v7
- name: Scan for unused code
  uses: albovsky/lethen@<version>
  with:
    baseline: baseline.json
```

The action is part of every release from 3.10.0; pin the release tag, or a commit, and `version` defaults to the Lethen release with that tag. Its inputs:

| Input | Default | Meaning |
| --- | --- | --- |
| `version` | the action's own version | A release version, `latest` for the newest stable release, or `source` to build the action's checkout of Lethen |
| `args` | none | Further `lethen scan` arguments with shell quoting, such as `--schemes App --targets App` |
| `working-directory` | `.` | Where to scan from; annotations still point at files from the repository root |
| `baseline` | none | A baseline file, relative to the working directory |
| `strict` | `true` | Fail the step when any result is reported |
| `format` | `github-actions` | The output format |
| `min-confidence` | the scan's default | `certain` fails the check only on `certain` results and leaves `likely` ones, such as declarations reachable from Objective-C or named in a string literal, to a local scan |

The `count` output is the number of results after the baseline and confidence filters, and `results-file` is the path of the results in the chosen format, for example to upload as an artifact. The scan always runs with `--relative-results --disable-update-check`, and settings from `.periphery.yml` still apply.

macOS release binaries are Apple silicon only, so use an Apple silicon runner such as `macos-26`. On Linux the release binary needs a Swift 6.3 or later toolchain on `PATH`, which it also uses to build the project; the action checks for `swift` but does not install it, so run the job in a container such as `swift:6.4-noble` or install Swift in an earlier step. Release binaries are tested on Ubuntu 22.04 and 24.04 images, and releases from 3.10.0 also on Ubuntu 26.04; the `swift:6.4` tag now points at Ubuntu 26.04, where the 3.9.0 binary cannot load `libxml2.so.2`, so pin an Ubuntu 24.04 image such as `swift:6.4-noble` when installing 3.9.0.

A baseline takes two steps: run `lethen scan --write-baseline baseline.json` once locally and commit the file, then pass it as `baseline`, so pull requests fail only on new results.

Without the action, run the command yourself:

```yaml
- name: Scan for unused code
  run: |
    lethen scan --format github-actions --relative-results --baseline baseline.json --strict --disable-update-check
```

Add `--min-confidence certain` to fail only on `certain` results. Pass `--disable-update-check` in CI; the optional update check otherwise contacts GitHub's releases API once per scan and can be disabled permanently with `disable_update_check: true` in the configuration file.

### GitLab

Use `--format gitlab-codequality --write-results gl-code-quality-report.json` and publish the file as a `codequality` report artifact.

### Xcode integration

Get the scan working in a terminal first. Then add an Aggregate target, give it a Run Script build phase containing the same command with the absolute path to `lethen` and `--format xcode`, and set `ENABLE_USER_SCRIPT_SANDBOXING` to `No` for that target, because the sandbox blocks access to the index store and sources. Mark the scheme as shared so the team gets it.

## Troubleshooting

**Wrong results in some files.** The index store can become stale, for example after a scan was interrupted. Run with `--clean-build`.

**Code used only under `#if` is reported.** Only the compiled branch is indexed. Ignore those declarations with a comment command, filter them from the results, or build and scan every configuration together with `--configurations` (for example `--configurations Debug Release` for an Xcode project).

**A local package's public API is reported.** Consumers outside the scanned scheme, such as the package's own test target, are not part of the scan. Scan the package separately or use `--retain-public` for it.

**Mixed Objective-C.** Direct uses from Objective-C into Swift are visible; see the Objective-C options above for selectors built from strings and key-value coding.

**Index store not found.** For managed SwiftPM scans lethen resolves the active build directory itself. For `--skip-build`, lethen looks in the package's build directory or, for Xcode projects, in its own and Xcode's DerivedData; otherwise pass `--index-store-path` and make sure the build enabled indexing.

Known Swift index-store bugs that can produce wrong results are listed in the [historical upstream guide](UPSTREAM-README.md#known-bugs).

## Compatibility with Periphery

Lethen is an independent fork of Periphery 3.8.0. Existing `.periphery.yml` files, `// periphery:` comment commands, the `PeripheryKit` library, and the `periphery` Bazel module keep working. The executable is `lethen`; substitute it for `periphery` in any command you carry over.
