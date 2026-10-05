import Configuration
import Foundation
import IndexStore
import Logger
import Shared
import SourceGraph
import SystemPackage

/// Marks Swift declarations used from Objective-C. Clang indexes a use of an `@objc` Swift symbol
/// under the symbol's clang USR, so each reference occurrence in the records of a clang unit whose USR
/// names a Swift declaration becomes a parentless reference at the Objective-C location. Parentless
/// references are roots, like top-level Swift code, so the declaration is used even when the
/// Objective-C code is itself unused; Objective-C declarations are not modelled.
///
/// Runs after the Swift indexer, whose declarations it resolves against. A USR that names no Swift
/// declaration, even after normalization, is dropped rather than guessed.
final class ObjCReferenceIndexer: Indexer {
    private let sourceFiles: [SourceFile: [IndexUnit]]
    private let graph: SourceGraphMutex
    private let evidence: ConfidenceEvidenceCollector
    private let logger: ContextualLogger
    private let configuration: Configuration

    required init(
        sourceFiles: [SourceFile: [IndexUnit]],
        graph: SourceGraphMutex,
        evidence: ConfidenceEvidenceCollector,
        logger: ContextualLogger,
        configuration: Configuration
    ) {
        self.sourceFiles = sourceFiles
        self.graph = graph
        self.evidence = evidence
        self.logger = logger.contextualized(with: "objc")
        self.configuration = configuration
        super.init(configuration: configuration)
    }

    /// Indexes the references and returns the files whose text could not be read for string literals.
    func perform() throws -> [FilePath] {
        let interval = logger.beginInterval("index:objc")

        // The index shows references by symbol, not the names that runtime lookups spell in strings and
        // selectors, so those count for the string-literal rule as Swift literals do. Each source file
        // is read once for both that and its `@import` statements.
        let sourcesByPath = Dictionary(uniqueKeysWithValues: sourceFiles.keys.map { ($0.path, $0) })
        var importsByFile: [SourceFile: [ImportStatement]] = [:]
        let analyzesImports = !configuration.disableUnusedImportAnalysis
        let sourceLiterals = ClangLiteralScanner.scan(files: sourceFiles.keys.map(\.path).sorted()) { path, bytes in
            guard analyzesImports, let file = sourcesByPath[path] else { return }

            let statements = ClangImportScanner.imports(in: bytes, file: file)
            if !statements.isEmpty {
                importsByFile[file] = statements
            }
        }

        // An import is checked only for a module the scan indexed Swift code of, as for Swift imports.
        let indexedModules = graph.withLock { graph in
            Set(importsByFile.values.joined().map(\.module).filter { graph.isModuleIndexed($0) })
        }
        let checkedFiles = importsByFile.filter { $0.value.contains { indexedModules.contains($0.module) } }.keys.sorted()
        var neededRecords: Set<RecordKey> = []
        for file in checkedFiles {
            neededRecords.formUnion(recordKeys(of: file))
        }

        let records = recordJobs(neededRecords: neededRecords)

        let results = try JobPool(jobs: records).flatMap { record -> [RecordResult] in
            let reader = try RecordReader(indexStore: record.store, recordName: record.name)
            var occurrences: [Occurrence] = []
            var referencedUSRs: Set<String> = []

            reader.forEach(occurrence: { occurrence in
                let usr = occurrence.symbol.usr
                guard occurrence.roles.contains(.reference) else { return }

                // A forward declaration (`@class Name;`, `@protocol Name;`) is indexed as a reference
                // with no relation, but it names the type without using it, and needs no import.
                if Self.forwardDeclarableKinds.contains(occurrence.symbol.kind) {
                    var hasRelation = false
                    occurrence.forEach(relation: { _, _ in hasRelation = true })
                    guard hasRelation else { return }
                }

                if record.collectsReferencedUSRs {
                    referencedUSRs.insert(usr)
                }

                guard usr.hasPrefix("c:"),
                      occurrence.roles.isDisjoint(with: [.definition, .declaration])
                else { return }

                let location = occurrence.location
                occurrences.append(Occurrence(usr: usr, file: record.file, line: location.line, column: location.column))
            })

            return [RecordResult(key: record.key, occurrences: occurrences, referencedUSRs: referencedUSRs)]
        }
        let occurrences = results.flatMap(\.occurrences)

        let headerLiterals = ClangLiteralScanner.scan(
            files: Set(records.map(\.file.path)).subtracting(sourcesByPath.keys).sorted()
        )
        var literalNames = sourceLiterals.names
        literalNames.formUnion(headerLiterals.names)
        let literals = (
            names: literalNames,
            unreadFiles: (sourceLiterals.unreadFiles + headerLiterals.unreadFiles).sorted()
        )
        for file in literals.unreadFiles {
            logger.debug("Cannot read \(file.string) for string literals")
        }

        let referencedModules = try referencedModulesByFile(
            checkedFiles: checkedFiles,
            importsByFile: importsByFile,
            indexedModules: indexedModules,
            referencedUSRs: Dictionary(results.map { ($0.key, $0.referencedUSRs) }, uniquingKeysWith: { $0.union($1) })
        )

        var unmatched = 0
        graph.withLock { graph in
            let resolver = USRResolver(graph: graph)
            var references: Set<Reference> = []

            for occurrence in occurrences {
                guard let (usr, declaration) = resolver.resolve(occurrence.usr) else {
                    unmatched += 1
                    continue
                }

                let location = Location(file: occurrence.file, line: occurrence.line, column: occurrence.column)
                references.insert(Self.reference(to: declaration, usr: usr, at: location))

                // Message syntax (`[UIColor wmf_blue]`) names only the accessor method, while Swift code
                // reading the property references the property itself.
                if declaration.kind.isAccessorKind, let property = declaration.parent, property.kind.isVariableKind,
                   let propertyUsr = property.usrs.sorted().first
                {
                    references.insert(Self.reference(to: property, usr: propertyUsr, at: location))
                }
            }

            graph.add(references)
            evidence.add {
                $0.addClangLiteralTokens(literals.names.tokens)
                $0.addClangLiteralSelectors(literals.names.selectors)
            }

            // Not `addIndexedModules`: the app target's clang units name no module, and a module written
            // in Objective-C must not become one the Swift imports of are checked.
            for (file, statements) in importsByFile.sorted(by: { $0.key < $1.key }) {
                file.importStatements = statements
                file.clangReferencedModules = referencedModules[file] ?? []
                graph.addIndexedSourceFile(file)
            }
            logger.debug("Added \(references.count) references from \(sourceFiles.count) C and Objective-C files; \(unmatched) clang references name no Swift declaration")
        }

        logger.endInterval(interval)
        return literals.unreadFiles
    }

    // MARK: - Private

    private static func reference(to declaration: Declaration, usr: String, at location: Location) -> Reference {
        let reference = Reference(
            name: declaration.name,
            kind: .normal,
            declarationKind: declaration.kind,
            usr: usr,
            location: location
        )
        reference.isFromObjectiveC = true
        return reference
    }

    private static let forwardDeclarableKinds: Set<SymbolKind> = [.class, .protocol]

    private struct RecordJob {
        let store: IndexStore
        let name: String
        let file: SourceFile
        let key: RecordKey
        /// Whether the record's references decide what the file that includes it needs to import.
        let collectsReferencedUSRs: Bool
    }

    private struct Occurrence {
        let usr: String
        let file: SourceFile
        let line: Int
        let column: Int
    }

    private struct RecordResult {
        let key: RecordKey
        let occurrences: [Occurrence]
        let referencedUSRs: Set<String>
    }

    /// The records of the file's units that are not system headers: its own and those it includes.
    private func recordKeys(of file: SourceFile) -> Set<RecordKey> {
        var keys: Set<RecordKey> = []
        for unit in sourceFiles[file] ?? [] {
            unit.unit.forEach(dependency: { dependency in
                guard dependency.kind == .record, !dependency.isSystem else { return }

                keys.insert(RecordKey(store: ObjectIdentifier(unit.store), name: dependency.name))
            })
        }
        return keys
    }

    /// Each record once: a header's record is shared by every unit that includes it. A record's
    /// occurrences are located in the record's own file, which for a header is not the unit's main file.
    private func recordJobs(neededRecords: Set<RecordKey>) -> [RecordJob] {
        let filesByPath = Dictionary(uniqueKeysWithValues: sourceFiles.keys.map { ($0.path, $0) })
        var seen: Set<RecordKey> = []
        var jobs: [RecordJob] = []

        for (sourceFile, units) in sourceFiles.sorted(by: { $0.key < $1.key }) {
            for unit in units {
                unit.unit.forEach(dependency: { dependency in
                    guard dependency.kind == .record, !dependency.isSystem else { return }

                    let key = RecordKey(store: ObjectIdentifier(unit.store), name: dependency.name)
                    guard seen.insert(key).inserted else { return }

                    let path = FilePath.makeAbsolute(dependency.filePath)
                    // An excluded file is as if absent, so neither its uses of Swift declarations nor its
                    // uses of imported modules count.
                    guard !configuration.indexExcludeMatchers.anyMatch(filename: path.string) else { return }

                    let file = filesByPath[path] ?? SourceFile(path: path, modules: sourceFile.modules)
                    jobs.append(RecordJob(
                        store: unit.store,
                        name: dependency.name,
                        file: file,
                        key: key,
                        collectsReferencedUSRs: neededRecords.contains(key)
                    ))
                })
            }
        }

        return jobs
    }

    /// The modules, by qualified name, whose symbols each checked file uses, as far as the index shows.
    ///
    /// A file uses what its own record and the headers it includes reference, since a header's uses are
    /// compile requirements of the translation unit too, and counting them errs toward keeping imports.
    /// A module also counts as used when the file uses a symbol of a non-system module it depends on:
    /// the module may re-export it, as `export *` in a module map does by default. And a module the
    /// index cannot speak for counts as used, never as unused: one with no module unit in the stores,
    /// as every SwiftPM module is, or one the file's units do not list as imported.
    private func referencedModulesByFile(
        checkedFiles: [SourceFile],
        importsByFile: [SourceFile: [ImportStatement]],
        indexedModules: Set<String>,
        referencedUSRs: [RecordKey: Set<String>]
    ) throws -> [SourceFile: Set<String>] {
        guard !checkedFiles.isEmpty else { return [:] }

        var stores: [IndexStore] = []
        for unit in sourceFiles.values.joined() where !stores.contains(where: { $0 === unit.store }) {
            stores.append(unit.store)
        }
        let symbols = try ClangModuleSymbolMap(stores: stores, importedModules: indexedModules, logger: logger)

        var result: [SourceFile: Set<String>] = [:]
        for file in checkedFiles {
            let usrs = recordKeys(of: file).reduce(into: Set<String>()) { $0.formUnion(referencedUSRs[$1] ?? []) }
            var referenced = symbols.modules(declaring: usrs)
            // A Swift declaration's clang USR names its module, so a use of one counts for that module even
            // when no Swift declaration resolves to the USR: the Swift index records a case of an `@objc`
            // enum nested in a class under its Swift USR only.
            referenced.formUnion(usrs.compactMap(ClangUSR.module(of:)))
            let referencedTopLevel = Set(referenced.map(ClangModuleSymbolMap.topLevel))
            let importedByUnits = importedModules(of: file)

            for module in Set((importsByFile[file] ?? []).map(\.module)) where indexedModules.contains(module) {
                let uses = !symbols.modulesWithUnits.contains(module) || !importedByUnits.contains(module)
                    || !referencedTopLevel.isDisjoint(with: symbols.transitiveDependencies(of: module))
                if uses {
                    referenced.insert(module)
                }
            }

            result[file] = referenced
        }

        return result
    }

    /// The top-level names of the modules the file's units import.
    private func importedModules(of file: SourceFile) -> Set<String> {
        var modules: Set<String> = []
        for unit in sourceFiles[file] ?? [] {
            unit.unit.forEach(dependency: { dependency in
                if dependency.kind == .unit {
                    modules.insert(ClangModuleSymbolMap.topLevel(dependency.moduleName))
                }
            })
        }
        return modules
    }

    /// Resolves a clang USR to the Swift declaration it names: by the USR itself, which clang writes
    /// with the Swift module when it sees the generated `-Swift.h` declaration, and otherwise by the
    /// module-less form, such as a class known only from an `@class` forward declaration. A module-less
    /// USR that two modules' declarations share is ambiguous and resolves to nothing.
    struct USRResolver {
        private let graph: SourceGraph
        private let declarationsByNormalizedUSR: [String: (usr: String, declaration: Declaration)?]

        init(graph: SourceGraph) {
            self.graph = graph

            var index: [String: (usr: String, declaration: Declaration)?] = [:]
            for declaration in graph.allDeclarations where declaration.isObjcAccessible {
                for usr in declaration.usrs where usr.hasPrefix("c:") {
                    let normalized = ClangUSR.normalized(usr)
                    if let existing = index[normalized] {
                        if existing?.declaration !== declaration {
                            index[normalized] = .some(nil)
                        }
                    } else {
                        index[normalized] = (usr, declaration)
                    }
                }
            }
            declarationsByNormalizedUSR = index
        }

        func resolve(_ usr: String) -> (usr: String, declaration: Declaration)? {
            if let declaration = graph.declaration(withUsr: usr) {
                return (usr, declaration)
            }

            return declarationsByNormalizedUSR[ClangUSR.normalized(usr)] ?? nil
        }
    }
}

/// Clang USRs for Objective-C symbols defined in Swift.
enum ClangUSR {
    /// The USR without the defining module. Swift writes `c:@M@App@objc(cs)Name` for an `@objc` class in
    /// module `App`, and `c:@CM@App@objc(cs)Name(im)method` (with an empty category name,
    /// `c:@CM@App@@objc(cs)NSObject(im)method`, for an extension of a class from another module) for an
    /// `@objc` member declared in an extension. Clang writes the module-less form when it knows the
    /// symbol only from Objective-C declarations. Any other USR is returned unchanged.
    static func normalized(_ usr: String) -> String {
        if let rest = dropModule(from: usr, prefix: "c:@M@") {
            // Objective-C USRs start `c:objc(`; C ones, such as an `@objc` enum's, start `c:@`.
            return rest.hasPrefix("objc(") ? "c:" + rest : "c:@" + rest
        }

        if let rest = dropModule(from: usr, prefix: "c:@CM@") {
            return "c:" + (rest.hasPrefix("@") ? rest.dropFirst() : rest)
        }

        return usr
    }

    /// The module a Swift-generated USR names: `WMFData` for `c:@M@WMFData@E@ImageWidth@ImageWidthW3840`
    /// and for `c:@CM@WMFData@objc(cs)Store(im)reload`. `nil` for any other USR, including the module-less
    /// forms clang writes for symbols it knows only from Objective-C declarations.
    static func module(of usr: String) -> String? {
        for prefix in ["c:@M@", "c:@CM@"] where usr.hasPrefix(prefix) {
            let afterPrefix = usr.dropFirst(prefix.count)
            guard let moduleEnd = afterPrefix.firstIndex(of: "@"), moduleEnd != afterPrefix.startIndex else { return nil }

            return String(afterPrefix[..<moduleEnd])
        }

        return nil
    }

    /// What follows `prefix` and the module name after it, or `nil` when `usr` does not start with them.
    private static func dropModule(from usr: String, prefix: String) -> Substring? {
        guard usr.hasPrefix(prefix) else { return nil }

        let afterPrefix = usr.dropFirst(prefix.count)
        guard let moduleEnd = afterPrefix.firstIndex(of: "@"), moduleEnd != afterPrefix.startIndex else { return nil }

        return afterPrefix[afterPrefix.index(after: moduleEnd)...]
    }
}
