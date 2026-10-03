import Foundation
import IndexStore
import Shared
import SystemPackage

/// Decides whether a managed SwiftPM index store can be reused instead of cleaning the build.
///
/// SwiftPM does not recompile a file when only indexing flags change, so an object compiled without
/// indexing never gains a unit, and an object recompiled without indexing keeps its old unit. Timestamps
/// alone cannot tell these apart because the compiler writes a unit shortly before its object file.
/// Incremental builds also do not always recompile a module's importers: changing an enum payload from
/// `Int` to `Int64` leaves a caller that writes `.number(42)` compiled, and indexed, against the old case.
///
/// So reuse works on whole modules, and every build lethen verifies ends with a stamp:
///
/// 1. Before building, a module is dirty when an object of it is newer than the stamp (another build
///    compiled it without lethen's indexing), a source of it changed after the stamp, or a source of it
///    has no unit. Every object of a dirty module and of each module importing it, transitively, is
///    deleted, so the indexed build recompiles them. An object newer than the stamp that belongs to no
///    indexed module cannot be reasoned about, and the caller cleans.
/// 2. After building, every package source must have a unit for its own module, every object this build
///    wrote must have a unit this build wrote, and every importer of a module this build recompiled must
///    have been recompiled in full.
///
/// Anything that cannot be verified is reported, and the caller falls back to a clean build.
///
/// A target the build never compiles, such as an executable used only by a command plugin, has no units
/// and no objects. It is not part of the contract: verification records it in the stamp, and the next
/// scan reuses the tree only while it still has no objects. A target with objects but no units, or with
/// units for only some of its sources, was compiled without indexing and cleans.
struct SPMIndexFreshness {
    /// SwiftPM does not rebuild when only `-Xswiftc` flags change, so a stamp from other arguments or
    /// another compiler cannot vouch for the objects in the tree.
    struct Stamp: Codable, Equatable {
        var format = 3
        let swiftVersion: String
        let buildArguments: [String]
        /// Modules of targets the build did not compile, sorted. Verification recomputes them after every
        /// build, so they inform the next preparation but never decide whether a stamp matches.
        var unbuiltTargets: [String] = []

        /// Whether a stamp written by another build vouches for this one's tree.
        func describesSameBuild(as other: Stamp) -> Bool {
            format == other.format && swiftVersion == other.swiftVersion && buildArguments == other.buildArguments
        }
    }

    struct Source: Hashable {
        let path: FilePath
        let module: String
        /// Names a build directory of the source's target can carry: the target, its module, and the
        /// products it belongs to. swiftbuild names directories `<Name>-t.build` or `<Name>-p.build`, the
        /// native build system `<Module>.build`.
        var directoryNames: Set<String> = []
    }

    struct Verification: Equatable {
        var issues: [Issue] = []
        /// Modules of targets with no unit and no object: the build never compiled them.
        var unbuiltTargets: Set<String> = []
    }

    enum Preparation: Equatable {
        /// Delete these objects, then build.
        case recompile(objects: Set<FilePath>, modules: Set<String>)
        case clean(reason: String)
    }

    enum Issue: Equatable, CustomStringConvertible {
        case missingUnit(FilePath)
        case unitNotRewritten(FilePath)
        case unitOlderThanSource(FilePath)
        case unexpectedModule(FilePath, expected: String, found: String)
        case unresolvedObject(FilePath, recorded: String)
        case importerNotRecompiled(module: String, importer: String)
        case notAPackageSource(FilePath)
        case compiledWithoutIndexing(target: String, object: FilePath)

        var description: String {
            switch self {
            case let .missingUnit(path):
                "no unit for \(path)"
            case let .unitNotRewritten(path):
                "\(path) was recompiled without indexing"
            case let .unitOlderThanSource(path):
                "unit for \(path) is older than the source"
            case let .unexpectedModule(path, expected, found):
                "unit for \(path) belongs to module \(found), expected \(expected)"
            case let .unresolvedObject(path, recorded):
                "object \(recorded) for \(path) matches no single object file in the build"
            case let .importerNotRecompiled(module, importer):
                "\(module) was recompiled but \(importer), which imports it, was not"
            case let .notAPackageSource(path):
                "\(path) has a unit but is no longer a source of the package"
            case let .compiledWithoutIndexing(target, object):
                "\(target) has no units but was compiled, as \(object)"
            }
        }
    }

    let storePath: FilePath
    let buildRoot: FilePath
    let packageRoot: FilePath
    let stampPath: FilePath

    /// - Parameters:
    ///   - buildRoot: the directory holding the build's object files. swiftbuild keeps them under
    ///     `Intermediates.noindex` and records relocatable object paths in units; the native build system
    ///     keeps them beside the products and records real paths.
    ///   - packageRoot: the root package's directory. A unit for a file under it that is not a current
    ///     source, such as one whose target was removed or which a target now excludes, would still be
    ///     analyzed, so it cannot be reused.
    init(storePath: FilePath, buildRoot: FilePath, packageRoot: FilePath) {
        self.storePath = storePath
        self.buildRoot = buildRoot
        self.packageRoot = packageRoot
        stampPath = storePath.removingLastComponent().appending("lethen-build-stamp.json")
    }

    // MARK: - Stamp

    func readStamp() -> (stamp: Stamp, date: Date)? {
        guard let data = FileManager.default.contents(atPath: stampPath.string),
              let stamp = try? JSONDecoder().decode(Stamp.self, from: data),
              let date = modificationDate(stampPath)
        else { return nil }

        return (stamp, date)
    }

    func writeStamp(_ stamp: Stamp) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(stamp).write(to: stampPath.url, options: .atomic)
    }

    func removeStamp() throws {
        if stampPath.exists {
            try FileManager.default.removeItem(atPath: stampPath.string)
        }
    }

    // MARK: - Before building

    /// - Parameter unbuiltTargets: the modules the stamp recorded as never compiled.
    func prepare(sources allSources: Set<Source>, stampDate: Date, unbuiltTargets: Set<String> = []) throws -> Preparation {
        let units = try sourceUnits()
        if let unresolved = units.first(where: { $0.object == nil }) {
            return .clean(reason: "object \(unresolved.recordedObject) matches no single object file")
        }
        if let removed = unitsOutsidePackageSources(units, sources: allSources).first {
            return .clean(reason: "\(removed) has a unit but is no longer a source of the package")
        }

        let modulesByDirectory = moduleObjectDirectories(units)
        let objects = objectFiles()

        // A recorded target that is still without units stays out of the contract only while it is still
        // without objects. One that has units now is checked like any other module, and verification
        // rejects units it did not rewrite.
        let unitModules = Set(units.map(\.module))
        let unbuilt = unbuiltTargets.subtracting(unitModules)
        let unbuiltSources = allSources.filter { unbuilt.contains($0.module) }
        for module in unbuilt.sorted() {
            let names = unbuiltSources.filter { $0.module == module }.reduce(into: Set<String>()) { $0.formUnion($1.directoryNames) }
            if let object = Self.firstObject(of: objects, named: names, excluding: Set(modulesByDirectory.keys)) {
                return .clean(reason: "\(module) was recorded as not built but now has objects, such as \(object)")
            }
        }
        let sources = allSources.subtracting(unbuiltSources)
        var resolvedDirectories: [FilePath: FilePath] = [:]
        func module(of object: ObjectFile) -> String? {
            guard let directory = Self.targetBuildDirectory(of: object.path) else { return nil }

            if resolvedDirectories[directory] == nil {
                resolvedDirectories[directory] = Self.resolved(directory)
            }
            return resolvedDirectories[directory].flatMap { modulesByDirectory[$0] }
        }
        var dirty: Set<String> = []

        for object in objects where object.date > stampDate {
            guard let module = module(of: object) else {
                return .clean(reason: "\(object.path) changed after the last indexed build and belongs to no indexed module")
            }

            dirty.insert(module)
        }

        let indexedFiles = Set(units.map(\.mainFile))
        for source in sources {
            let path = Self.resolved(source.path)
            if !indexedFiles.contains(path) {
                dirty.insert(source.module)
            } else if let date = modificationDate(path), date > stampDate {
                dirty.insert(source.module)
            }
        }

        let affected = Self.closure(of: dirty, importers: Self.importers(units))
        let recompiled = Set(objects.filter { module(of: $0).map(affected.contains) ?? false }.map(\.path))
        return .recompile(objects: recompiled, modules: affected)
    }

    // MARK: - After building

    func verify(sources: Set<Source>, buildStart: Date) throws -> Verification {
        let units = try sourceUnits()
        let unitsByFile = Dictionary(grouping: units, by: \.mainFile)
        var result = Verification()
        var issues: [Issue] = unitsOutsidePackageSources(units, sources: sources).map { .notAPackageSource($0) }

        // A module none of whose sources has a unit and that has no object of its own was never compiled.
        // One with objects was compiled without indexing; one with some units is checked source by source.
        let unitModules = Set(units.map(\.module))
        let claimedDirectories = Set(moduleObjectDirectories(units).keys)
        var objects: [ObjectFile]?
        for (module, moduleSources) in Dictionary(grouping: sources, by: \.module).sorted(by: { $0.key < $1.key }) {
            guard !unitModules.contains(module),
                  !moduleSources.contains(where: { !(unitsByFile[Self.resolved($0.path)] ?? []).isEmpty })
            else { continue }

            if objects == nil {
                objects = objectFiles()
            }
            let names = moduleSources.reduce(into: Set<String>()) { $0.formUnion($1.directoryNames) }
            if let object = Self.firstObject(of: objects ?? [], named: names, excluding: claimedDirectories) {
                issues.append(.compiledWithoutIndexing(target: module, object: object))
            } else {
                result.unbuiltTargets.insert(module)
            }
        }

        for source in sources.sorted(by: { $0.path.string < $1.path.string }) where !result.unbuiltTargets.contains(source.module) {
            let path = Self.resolved(source.path)
            guard let fileUnits = unitsByFile[path], !fileUnits.isEmpty else {
                issues.append(.missingUnit(path))
                continue
            }

            let sourceDate = modificationDate(path)
            for unit in fileUnits {
                if unit.module != source.module {
                    issues.append(.unexpectedModule(path, expected: source.module, found: unit.module))
                }
                if let sourceDate, unit.date < sourceDate {
                    issues.append(.unitOlderThanSource(path))
                }
            }
        }

        // Any object this build wrote must come with a unit this build wrote, including dependencies.
        var recompiledModules: Set<String> = []
        var fullyRecompiled: [String: Bool] = [:]
        for unit in units {
            guard let object = unit.object, let objectDate = modificationDate(object) else {
                issues.append(.unresolvedObject(unit.mainFile, recorded: unit.recordedObject))
                continue
            }

            let rebuilt = objectDate >= buildStart
            fullyRecompiled[unit.module] = (fullyRecompiled[unit.module] ?? true) && rebuilt
            guard rebuilt else { continue }

            recompiledModules.insert(unit.module)
            if unit.date < buildStart {
                issues.append(.unitNotRewritten(unit.mainFile))
            }
        }

        // The compiler does not always recompile importers, so the build must have been asked to.
        let importers = Self.importers(units)
        for module in recompiledModules.sorted() {
            for importer in (importers[module] ?? []).sorted() where fullyRecompiled[importer] != true {
                issues.append(.importerNotRecompiled(module: module, importer: importer))
            }
        }

        result.issues = issues
        return result
    }

    // MARK: - Private

    private struct SourceUnit {
        let mainFile: FilePath
        let module: String
        let imports: Set<String>
        let recordedObject: String
        /// The object file on disk, or nil when the recorded path matches none or several.
        let object: FilePath?
        let date: Date
    }

    private struct ObjectFile {
        let path: FilePath
        let date: Date
    }

    private func sourceUnits() throws -> [SourceUnit] {
        let store = try IndexStore(path: storePath.string)
        let unitsDirectory = try unitsDirectory()

        return store.units.compactMap { unit -> SourceUnit? in
            guard !unit.isSystem, unit.isSource, !unit.mainFile.isEmpty, !unit.outputFile.isEmpty else { return nil }
            guard let date = modificationDate(unitsDirectory.appending(unit.name)) else { return nil }

            let workingDirectory = FilePath(unit.workingDirectory)
            let recorded = FilePath.makeAbsolute(unit.outputFile, relativeTo: workingDirectory)
            let module = unit.moduleName
            var imports: Set<String> = []
            unit.forEach(dependency: { dependency in
                if !dependency.isSystem, !dependency.moduleName.isEmpty, dependency.moduleName != module {
                    imports.insert(dependency.moduleName)
                }
            })

            return SourceUnit(
                mainFile: Self.resolved(FilePath.makeAbsolute(unit.mainFile, relativeTo: workingDirectory)),
                module: module,
                imports: imports,
                recordedObject: recorded.string,
                object: resolveObject(recorded),
                date: date
            )
        }
    }

    /// Files under the package root, outside the build's scratch directory where generated sources live,
    /// that have units but are not current package sources.
    private func unitsOutsidePackageSources(_ units: [SourceUnit], sources: Set<Source>) -> [FilePath] {
        let current = Set(sources.map { Self.resolved($0.path) })
        let package = Self.resolved(packageRoot)
        // swiftbuild's build root is <scratch>/out; the native build system's is the scratch directory.
        let intermediates = buildRoot.appending("Intermediates.noindex")
        let scratch = Self.resolved(FileManager.default.fileExists(atPath: intermediates.string) ? buildRoot.removingLastComponent() : buildRoot)

        return Set(units.map(\.mainFile))
            .filter { $0.starts(with: package) && !$0.starts(with: scratch) && !current.contains($0) }
            .sorted()
    }

    /// The `<Target>.build` directory each indexed module compiles into, with symlinks resolved. Objects are
    /// matched to modules by it rather than by their own directory, because a build also writes objects no
    /// unit names below it, such as the module-wrap object swiftbuild writes on Linux in `Modules/`.
    private func moduleObjectDirectories(_ units: [SourceUnit]) -> [FilePath: String] {
        var result: [FilePath: String] = [:]
        var seen: Set<FilePath> = []
        for unit in units {
            guard let object = unit.object, let directory = Self.targetBuildDirectory(of: object),
                  seen.insert(directory).inserted
            else { continue }

            result[Self.resolved(directory)] = unit.module
        }
        return result
    }

    /// The nearest enclosing directory named like `<Target>.build` (native) or `<Target>-<kind>.build`
    /// (swiftbuild).
    private static func targetBuildDirectory(of object: FilePath) -> FilePath? {
        var directory = object.removingLastComponent()
        while let name = directory.lastComponent?.string {
            if name.hasSuffix(".build"), name != ".build" {
                return directory
            }
            directory = directory.removingLastComponent()
        }
        return nil
    }

    /// Object files of target builds, which both build systems keep in a `<Target>.build` directory.
    /// Linked products and package checkouts are not compiled by this build's targets.
    private func objectFiles() -> [ObjectFile] {
        let intermediates = buildRoot.appending("Intermediates.noindex")
        let root = FileManager.default.fileExists(atPath: intermediates.string) ? intermediates : buildRoot
        let skipped: Set = ["checkouts", "repositories", "artifacts", "index-build", "prebuilts", "index", "ModuleCache"]
        let keys: [URLResourceKey] = [.contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root.url, includingPropertiesForKeys: keys) else { return [] }

        let rootDepth = root.url.pathComponents.count
        var result: [ObjectFile] = []
        for case let url as URL in enumerator {
            if skipped.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension == "o",
                  url.deletingLastPathComponent().pathComponents.dropFirst(rootDepth).contains(where: { $0.hasSuffix(".build") }),
                  let date = try? url.resourceValues(forKeys: Set(keys)).contentModificationDate
            else { continue }

            result.append(ObjectFile(path: FilePath(url.path), date: date))
        }
        return result
    }

    /// The first object, by path, in a `<Name>.build` or `<Name>-<kind>.build` directory for one of the
    /// names, skipping directories that indexed modules compile into. Matching is deliberately broad: an
    /// object wrongly attributed to a target only turns "never built" into "compiled without indexing",
    /// which cleans.
    private static func firstObject(of objects: [ObjectFile], named names: Set<String>, excluding claimed: Set<FilePath>) -> FilePath? {
        guard !names.isEmpty else { return nil }

        var resolvedDirectories: [FilePath: FilePath] = [:]
        return objects.lazy
            .map(\.path)
            .filter { object in
                guard let directory = targetBuildDirectory(of: object), let name = directory.lastComponent?.string else { return false }

                let resolved = resolvedDirectories[directory] ?? Self.resolved(directory)
                resolvedDirectories[directory] = resolved
                let base = String(name.dropLast(".build".count))
                return !claimed.contains(resolved) && names.contains { base == $0 || base.hasPrefix($0 + "-") }
            }
            .min { $0.string < $1.string }
    }

    /// For each module, the modules whose units import it.
    private static func importers(_ units: [SourceUnit]) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for unit in units {
            for imported in unit.imports {
                result[imported, default: []].insert(unit.module)
            }
        }
        return result
    }

    private static func closure(of modules: Set<String>, importers: [String: Set<String>]) -> Set<String> {
        var result = modules
        var pending = Array(modules)
        while let module = pending.popLast() {
            for importer in importers[module] ?? [] where result.insert(importer).inserted {
                pending.append(importer)
            }
        }
        return result
    }

    /// The native build system records real object paths. swiftbuild records a relocatable path ending in
    /// `<Package>.build/<Configuration>/<Target>.build/.../<File>.o`, found under `Intermediates.noindex`.
    /// A path that resolves to nothing, or to more than one file, is not trusted.
    private func resolveObject(_ recorded: FilePath) -> FilePath? {
        if FileManager.default.fileExists(atPath: recorded.string) {
            return recorded
        }

        let intermediates = buildRoot.appending("Intermediates.noindex")
        let components = Array(recorded.components)
        let matches = components.indices
            .filter { components[$0].string.hasSuffix(".build") }
            .map { index in components[index...].reduce(intermediates) { $0.appending($1) } }
            .filter { FileManager.default.fileExists(atPath: $0.string) }
        return matches.count == 1 ? matches[0] : nil
    }

    private func unitsDirectory() throws -> FilePath {
        let versions = try FileManager.default.contentsOfDirectory(atPath: storePath.string)
            .filter { $0.hasPrefix("v") && Int($0.dropFirst()) != nil }
        guard versions.count == 1, let version = versions.first else {
            throw LethenError.packageError(message: "Expected one index store format directory in \(storePath), found \(versions.sorted())")
        }

        return storePath.appending(version).appending("units")
    }

    /// Units record the path the compiler was given, which can differ from the package path by symlinks
    /// such as /tmp and /private/tmp.
    private static func resolved(_ path: FilePath) -> FilePath {
        FilePath(URL(fileURLWithPath: path.lexicallyNormalized().string).resolvingSymlinksInPath().path)
    }

    private func modificationDate(_ path: FilePath) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path.string))?[.modificationDate] as? Date
    }
}
