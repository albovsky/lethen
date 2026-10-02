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
    private let logger: ContextualLogger
    private let configuration: Configuration

    required init(
        sourceFiles: [SourceFile: [IndexUnit]],
        graph: SourceGraphMutex,
        logger: ContextualLogger,
        configuration: Configuration
    ) {
        self.sourceFiles = sourceFiles
        self.graph = graph
        self.logger = logger.contextualized(with: "objc")
        self.configuration = configuration
        super.init(configuration: configuration)
    }

    /// Indexes the references and returns the files whose text could not be read for string literals.
    func perform() throws -> [FilePath] {
        let records = recordJobs()
        let interval = logger.beginInterval("index:objc")

        let occurrences = try JobPool(jobs: records).flatMap { record -> [Occurrence] in
            let reader = try RecordReader(indexStore: record.store, recordName: record.name)
            var occurrences: [Occurrence] = []

            reader.forEach(occurrence: { occurrence in
                let usr = occurrence.symbol.usr
                guard usr.hasPrefix("c:"),
                      occurrence.roles.contains(.reference),
                      occurrence.roles.isDisjoint(with: [.definition, .declaration])
                else { return }

                // A forward declaration (`@class Name;`, `@protocol Name;`) is indexed as a reference
                // with no relation, but it names the type without using it.
                if Self.forwardDeclarableKinds.contains(occurrence.symbol.kind) {
                    var hasRelation = false
                    occurrence.forEach(relation: { _, _ in hasRelation = true })
                    guard hasRelation else { return }
                }

                let location = occurrence.location
                occurrences.append(Occurrence(usr: usr, file: record.file, line: location.line, column: location.column))
            })

            return occurrences
        }

        // The index shows references by symbol, not the names that runtime lookups spell in strings and
        // selectors, so those count for the string-literal rule as Swift literals do.
        let literalFiles = Set(records.map(\.file.path)).union(sourceFiles.keys.map(\.path)).sorted()
        let literals = ClangLiteralScanner.scan(files: literalFiles)
        for file in literals.unreadFiles {
            logger.debug("Cannot read \(file.string) for string literals")
        }

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
            graph.addLiteralTokens(literals.tokens)
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
    }

    private struct Occurrence {
        let usr: String
        let file: SourceFile
        let line: Int
        let column: Int
    }

    /// Each record once: a header's record is shared by every unit that includes it. A record's
    /// occurrences are located in the record's own file, which for a header is not the unit's main file.
    private func recordJobs() -> [RecordJob] {
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
                    guard !configuration.indexExcludeMatchers.anyMatch(filename: path.string) else { return }

                    let file = filesByPath[path] ?? SourceFile(path: path, modules: sourceFile.modules)
                    jobs.append(RecordJob(store: unit.store, name: dependency.name, file: file))
                })
            }
        }

        return jobs
    }

    private struct RecordKey: Hashable {
        let store: ObjectIdentifier
        let name: String
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

    /// What follows `prefix` and the module name after it, or `nil` when `usr` does not start with them.
    private static func dropModule(from usr: String, prefix: String) -> Substring? {
        guard usr.hasPrefix(prefix) else { return nil }

        let afterPrefix = usr.dropFirst(prefix.count)
        guard let moduleEnd = afterPrefix.firstIndex(of: "@"), moduleEnd != afterPrefix.startIndex else { return nil }

        return afterPrefix[afterPrefix.index(after: moduleEnd)...]
    }
}
