import Configuration
import Foundation
import IndexStore
import Logger
import Shared
import SourceGraph
import SyntaxAnalysis
import SystemPackage

public struct IndexUnit {
    let store: IndexStore
    let unit: UnitReader
}

final class SwiftIndexer: Indexer {
    private let sourceFiles: [SourceFile: [IndexUnit]]
    private let graph: SourceGraphMutex
    private let evidence: ConfidenceEvidenceCollector
    private let logger: ContextualLogger
    private let configuration: Configuration
    private let swiftVersion: SwiftVersion

    required init(
        sourceFiles: [SourceFile: [IndexUnit]],
        graph: SourceGraphMutex,
        evidence: ConfidenceEvidenceCollector,
        logger: ContextualLogger,
        configuration: Configuration,
        swiftVersion: SwiftVersion
    ) {
        self.sourceFiles = sourceFiles
        self.graph = graph
        self.evidence = evidence
        self.logger = logger.contextualized(with: "swift")
        self.configuration = configuration
        self.swiftVersion = swiftVersion
        super.init(configuration: configuration)
    }

    /// Indexes the source files and returns the number of lines of code they contain, which is counted
    /// only when the scan reports statistics.
    func perform() throws -> Int? {
        let jobs = sourceFiles.map { file, units -> Job in
            Job(
                sourceFile: file,
                units: units,
                retainAllDeclarations: isRetained(file),
                graph: graph,
                evidence: evidence,
                logger: logger,
                configuration: configuration,
                swiftVersion: swiftVersion
            )
        }

        let phaseOneInterval = logger.beginInterval("index:swift:phase:one")

        try JobPool(jobs: jobs).forEach { job in
            if self.configuration.verbose {
                let phaseOneLogger = self.logger.contextualized(with: "phase:one")
                let elapsed = try Benchmark.measure { try job.phaseOne() }
                self.debug(logger: phaseOneLogger, sourceFile: job.sourceFile, elapsed: elapsed)
            } else {
                try job.phaseOne()
            }
        }

        logger.endInterval(phaseOneInterval)

        let phaseTwoInterval = logger.beginInterval("index:swift:phase:two")

        try JobPool(jobs: jobs).forEach { job in
            if self.configuration.verbose {
                let phaseTwoLogger = self.logger.contextualized(with: "phase:two")
                let elapsed = try Benchmark.measure { try job.phaseTwo() }
                self.debug(logger: phaseTwoLogger, sourceFile: job.sourceFile, elapsed: elapsed)
            } else {
                try job.phaseTwo()
            }
        }

        logger.endInterval(phaseTwoInterval)

        guard configuration.stats else { return nil }

        return jobs.reduce(into: 0) { $0 += $1.scannedLOC }
    }

    // MARK: - Private

    private func debug(logger: ContextualLogger, sourceFile: SourceFile, elapsed: String) {
        guard configuration.verbose else { return }

        let modules = sourceFile.modules.joined(separator: ", ")
        logger.debug("\(sourceFile.path.string) (\(modules)) (\(elapsed)s)")
    }

    private final class Job {
        let sourceFile: SourceFile
        private(set) var scannedLOC: Int = 0

        private let units: [IndexUnit]
        private let graph: SourceGraphMutex
        private let evidence: ConfidenceEvidenceCollector
        private let logger: ContextualLogger
        private let configuration: Configuration
        private var retainAllDeclarations: Bool
        private let swiftVersion: SwiftVersion

        required init(
            sourceFile: SourceFile,
            units: [IndexUnit],
            retainAllDeclarations: Bool,
            graph: SourceGraphMutex,
            evidence: ConfidenceEvidenceCollector,
            logger: ContextualLogger,
            configuration: Configuration,
            swiftVersion: SwiftVersion
        ) {
            self.sourceFile = sourceFile
            self.units = units
            self.retainAllDeclarations = retainAllDeclarations
            self.graph = graph
            self.evidence = evidence
            self.logger = logger
            self.configuration = configuration
            self.swiftVersion = swiftVersion
        }

        // swiftlint:disable nesting
        struct RawRelation {
            struct Symbol {
                let name: String
                let usr: String?
                let kind: SymbolKind
                let subKind: SymbolSubkind
            }

            let symbol: Symbol
            let roles: SymbolRoles
        }

        struct RawDeclaration {
            struct Key: Hashable {
                let kind: Declaration.Kind
                let name: String
                let isImplicit: Bool
                let isObjcAccessible: Bool
                let location: Location
            }

            let usr: String
            let kind: Declaration.Kind
            let name: String
            let isImplicit: Bool
            let isObjcAccessible: Bool
            let location: Location
            /// The module of the index unit that recorded the declaration.
            var module = ""

            var key: Key {
                Key(kind: kind, name: name, isImplicit: isImplicit, isObjcAccessible: isObjcAccessible, location: location)
            }
        }

        // swiftlint:enable nesting

        /// Phase one reads the index store and establishes the declaration hierarchy and the majority of references.
        /// Some references may depend upon declarations in other files, and thus their association is deferred until
        /// phase two.
        func phaseOne() throws {
            var rawDeclsByKey: [RawDeclaration.Key: [(RawDeclaration, [RawRelation])]] = [:]
            var references: Set<Reference> = []

            for unit in units {
                for recordName in unit.unit.recordNames {
                    let record = try RecordReader(indexStore: unit.store, recordName: recordName)

                    record.forEach(occurrence: { occurrence in
                        let usr = occurrence.symbol.usr
                        guard let location = self.transformLocation(occurrence.location) else { return }

                        // Every occurrence is evidence that its line was compiled, including the parameters and
                        // locals that analysis drops and symbols of any language.
                        occurrenceLocations[unit.unit.moduleName, default: []].insert(location)

                        guard Self.shouldProcessOccurrence(occurrence) else { return }

                        var relations: [RawRelation] = []
                        occurrence.forEach(relation: { relSymbol, relRoles in
                            relations.append(RawRelation(
                                symbol: .init(
                                    name: relSymbol.name,
                                    usr: relSymbol.usr,
                                    kind: relSymbol.kind,
                                    subKind: relSymbol.subkind
                                ),
                                roles: relRoles
                            ))
                        })

                        if !occurrence.roles.isDisjoint(with: [.definition, .declaration]) {
                            if let (decl, relations) = self.parseRawDeclaration(
                                occurrence,
                                usr,
                                location,
                                relations
                            ) {
                                var decl = decl
                                decl.module = unit.unit.moduleName
                                rawDeclsByKey[decl.key, default: []].append((decl, relations))
                            }
                        }

                        if occurrence.roles.contains(.reference) {
                            references.formUnion(self.parseReference(
                                occurrence,
                                usr,
                                location,
                                relations
                            ))
                        }

                        if occurrence.roles.contains(.implicit) {
                            references.formUnion(self.parseImplicit(
                                usr,
                                location,
                                relations
                            ))
                        }
                    })
                }
            }

            var newDeclarations: Set<Declaration> = []

            // Declarations are equal when their USRs are, so when two keys share USRs (an index built from
            // code that failed to type-check can give overloads the same USR) the first one inserted wins.
            // Walking keys in a fixed order keeps that choice the same in every process.
            let orderedKeys = rawDeclsByKey.keys.sorted {
                ($0.location, $0.name, $0.kind.rawValue, $0.isImplicit ? 1 : 0) < ($1.location, $1.name, $1.kind.rawValue, $1.isImplicit ? 1 : 0)
            }

            // Only the first copy of a USR set reaches the graph. Later copies (a declaration written in both
            // branches of a `#if` built in two configurations) must never become a reference parent or a
            // retained root, or marking one used would mark the kept declaration used without traversing it.
            var keptDeclarationsByUsrs: [Set<String>: Declaration] = [:]

            for key in orderedKeys {
                let values = rawDeclsByKey[key, default: []]
                let usrs = values.mapSet { $0.0.usr }
                let decl = Declaration(name: key.name, kind: key.kind, usrs: usrs, location: key.location)

                decl.isImplicit = key.isImplicit
                decl.indexedModules = values.mapSet { $0.0.module }
                decl.isObjcAccessible = key.isObjcAccessible

                let kept = keptDeclarationsByUsrs[usrs] ?? decl
                keptDeclarationsByUsrs[usrs] = kept

                if decl.isObjcAccessible, configuration.retainObjcAccessible {
                    graph.withLock { $0.markRetained(kept) }
                }

                let relations = values.flatMap(\.1)
                references.formUnion(parseDeclaration(kept, relations))

                newDeclarations.insert(decl)
                declarations.append(decl)
            }
            self.keptDeclarationsByUsrs = keptDeclarationsByUsrs

            graph.withLock { graph in
                graph.add(references)
                indexedReferences = references
                graph.add(newDeclarations)

                if retainAllDeclarations {
                    graph.markRetained(newDeclarations)
                }
            }

            establishDeclarationHierarchy()

            // Generated declarations are retained through their parent, so they are used only when
            // the declaration the macro was attached to is used. Parentless expansions stay roots,
            // except extensions: ExtensionReferenceBuilder folds those into the type they extend
            // (and retains extensions of external types), so a generated conformance such as
            // `extension Foo: Observable` does not keep `Foo` alive.
            let implicitDeclarations = declarations.filter {
                $0.isImplicit && !$0.kind.isExtensionKind && keptDeclarationsByUsrs[$0.usrs] === $0
            }
            graph.withLock { graph in
                implicitDeclarations.forEach { graph.markRetained($0) }
            }
        }

        /// Phase two associates latent references, and performs other actions that depend on the completed source graph.
        func phaseTwo() throws {
            if !configuration.disableUnusedImportAnalysis {
                graph.withLock { graph in
                    graph.addIndexedSourceFile(sourceFile)
                    graph.addIndexedModules(sourceFile.modules)
                }
            }

            let multiplexingSyntaxVisitor = try MultiplexingSyntaxVisitor(file: sourceFile, swiftVersion: swiftVersion)
            let declarationSyntaxVisitor = multiplexingSyntaxVisitor.add(DeclarationSyntaxVisitor.self)
            let importSyntaxVisitor = multiplexingSyntaxVisitor.add(ImportSyntaxVisitor.self)

            multiplexingSyntaxVisitor.visit()

            if configuration.stats {
                scannedLOC = SourceLOCCounter.countLines(
                    of: multiplexingSyntaxVisitor.syntax,
                    using: multiplexingSyntaxVisitor.locationConverter
                )
            }

            sourceFile.importStatements = importSyntaxVisitor.importStatements
            sourceFile.importsSwiftTesting = importSyntaxVisitor.importStatements.contains(where: { $0.module == "Testing" })

            if !configuration.disableUnusedImportAnalysis {
                for stmt in sourceFile.importStatements where stmt.isExported {
                    graph.withLock { graph in
                        graph.addExportedModule(stmt.module, exportedBy: sourceFile.modules)
                    }
                }
            }

            let locationBuilder = SourceLocationBuilder(
                file: sourceFile, locationConverter: multiplexingSyntaxVisitor.locationConverter
            )
            associateLatentReferences()
            associateDanglingReferences(
                topLevelStatements: TopLevelStatementLocator.ranges(in: multiplexingSyntaxVisitor.syntax, using: locationBuilder)
            )
            visitDeclarations(using: declarationSyntaxVisitor)
            let file = IndexedFile(
                sourceFile: sourceFile,
                syntax: multiplexingSyntaxVisitor.syntax,
                locationBuilder: locationBuilder,
                locationConverter: multiplexingSyntaxVisitor.locationConverter,
                declarations: declarations,
                fileCommands: multiplexingSyntaxVisitor.parseComments(),
                referencesByLocation: Dictionary(grouping: indexedReferences, by: \.location).mapValues(Set.init),
                occurrenceLocations: occurrenceLocations,
                retainsAllDeclarations: retainAllDeclarations,
                graph: graph,
                logger: logger,
                evidence: evidence
            )
            for analysis in SyntaxAnalysisList.all {
                try analysis.init(configuration: configuration).apply(to: file)
            }
        }

        // MARK: - Private

        private var declarations: [Declaration] = []
        /// The copy of each USR set that phase one added to the graph; other copies are never graph-visible.
        private var keptDeclarationsByUsrs: [Set<String>: Declaration] = [:]
        private var indexedReferences: Set<Reference> = []
        /// Locations of every index occurrence, by the module whose unit recorded them. A file built into
        /// several modules can compile different clauses in each.
        private var occurrenceLocations: [String: Set<Location>] = [:]
        private var childDeclsByParentUsr: [String: Set<Declaration>] = [:]
        private var referencesByUsr: [String: Set<Reference>] = [:]
        private var danglingReferences: [Reference] = []
        private var varParameterUsrs: Set<String> = []
        private var extensionUsrMap: [String: String] = [:]

        private func establishDeclarationHierarchy() {
            graph.withLock { graph in
                for (parent, decls) in childDeclsByParentUsr {
                    guard let parentDecl = graph.declaration(withUsr: parent) else {
                        if varParameterUsrs.contains(parent) {
                            // These declarations are children of a parameter and are redundant.
                            decls.forEach { graph.remove($0) }
                        }

                        continue
                    }

                    for decl in decls {
                        decl.parent = parentDecl
                    }

                    parentDecl.declarations.formUnion(decls)
                }
            }
        }

        private func associateLatentReferences() {
            for (usr, refs) in referencesByUsr {
                graph.withLock { graph in
                    if let decl = graph.declaration(withUsr: usr) {
                        for ref in refs {
                            associateUnsafe(ref, with: decl)
                        }
                    } else {
                        danglingReferences.append(contentsOf: refs)
                    }
                }
            }
        }

        // Swift does not associate some type references with the containing declaration, resulting in references
        // with no clear parent. Property references are one example: https://github.com/apple/swift/issues/56163
        private func associateDanglingReferences(topLevelStatements: [ClosedRange<Location>]) {
            guard !danglingReferences.isEmpty else { return }

            // Sort declarations to ensure deterministic candidate selection when
            // multiple declarations exist at the same location.
            let sortedDeclarations = declarations.sorted()

            let declsByLocation = sortedDeclarations
                .reduce(into: [Location: [Declaration]]()) { result, decl in
                    result[decl.location, default: []].append(decl)
                }
            let declsByLine = sortedDeclarations
                .reduce(into: [Int: [Declaration]]()) { result, decl in
                    result[decl.location.line, default: []].append(decl)
                }
            let sortedDeclLines = declsByLine.keys.sorted().reversed()

            for ref in danglingReferences {
                // References from top-level code have no parent declaration by definition. Leaving them unassociated
                // makes them root references; attributing them to a nearby declaration would hide their uses.
                if topLevelStatements.contains(where: { $0.contains(ref.location) }) {
                    continue
                }

                let sameLineCandidateDecls = declsByLocation[ref.location] ??
                    declsByLine[ref.location.line]
                var candidateDecls = [Declaration]()

                if let sameLineCandidateDecls {
                    candidateDecls = sameLineCandidateDecls
                } else {
                    // For references with no declaration on the same line, find the nearest preceding declaration.
                    if let line = sortedDeclLines.first(where: { $0 < ref.location.line }) {
                        candidateDecls = declsByLine[line]?.filter {
                            !$0.usrs.contains(ref.usr) &&
                                !$0.ancestralDeclarations.contains(where: { $0.usrs.contains(ref.usr) })
                        } ?? []
                    }
                }

                // The vast majority of the time there will only be a single declaration for this location,
                // however it is possible for there to be more than one. In that case, first attempt to associate with
                // a decl without a parent, as the reference may be a related type of a class/struct/etc.
                if let decl = candidateDecls.first(where: { $0.parent == nil }) {
                    associate(ref, with: keptDeclarationsByUsrs[decl.usrs] ?? decl)
                } else if let decl = candidateDecls.min() {
                    // Fallback to using the first declaration.
                    // Sorting the declarations helps in the situation where the candidate declarations includes a
                    // property/subscript, and a getter on the same line. The property/subscript is more likely to be
                    // the declaration that should hold the references.
                    associate(ref, with: keptDeclarationsByUsrs[decl.usrs] ?? decl)
                }
            }
        }

        private func visitDeclarations(using declarationVisitor: DeclarationSyntaxVisitor) {
            let declarationsByLocation = declarationVisitor.resultsByLocation

            for decl in declarations {
                guard let result = declarationsByLocation[decl.location] else { continue }

                applyDeclarationMetadata(to: decl, with: result)
            }
        }

        private func applyDeclarationMetadata(to decl: Declaration, with result: DeclarationSyntaxVisitor.Result) {
            graph.withLock { _ in
                if let accessibility = result.accessibility {
                    decl.accessibility = .init(value: accessibility, isExplicit: true)
                }

                decl.attributes = Set(result.attributes)
                decl.modifiers = Set(result.modifiers)
                decl.commentCommands = Set(result.commentCommands)
                decl.declaredType = result.variableType

                decl.hasGenericFunctionReturnedMetatypeParameters = result.hasGenericFunctionReturnedMetatypeParameters

                for ref in decl.references.union(decl.related) {
                    if result.inheritedTypeLocations.contains(ref.location) {
                        if decl.kind.isConformableKind, ref.declarationKind == .protocol {
                            ref.role = .conformedType
                        } else if decl.kind == .protocol, ref.declarationKind == .protocol {
                            ref.role = .refinedProtocolType
                        } else if decl.kind == .class || decl.kind == .associatedtype {
                            ref.role = .inheritedType
                        }
                    } else if result.variableTypeLocations.contains(ref.location) {
                        ref.role = .varType
                    } else if result.returnTypeLocations.contains(ref.location) {
                        ref.role = .returnType
                    } else if result.throwTypeLocations.contains(ref.location) {
                        ref.role = .throwType
                    } else if result.parameterTypeLocations.contains(ref.location) {
                        ref.role = .parameterType
                    } else if result.genericParameterLocations.contains(ref.location) {
                        ref.role = .genericParameterType
                    } else if result.genericConformanceRequirementLocations.contains(ref.location) {
                        ref.role = .genericRequirementType
                    } else if result.variableInitFunctionCallLocations.contains(ref.location) {
                        ref.role = .variableInitFunctionCall
                    } else if result.functionCallMetatypeArgumentLocations.contains(ref.location) {
                        ref.role = .functionCallMetatypeArgument
                    } else if result.typeInitializerLocations.contains(ref.location) {
                        ref.role = .initializerType
                    } else if result.variableInitExprLocations.contains(ref.location) {
                        ref.role = .initializerType
                    }
                }
            }
        }

        private func associate(_ ref: Reference, with decl: Declaration) {
            graph.withLock { _ in
                associateUnsafe(ref, with: decl)
            }
        }

        private func associateUnsafe(_ ref: Reference, with decl: Declaration) {
            ref.parent = decl

            if ref.kind == .related {
                decl.related.insert(ref)
            } else {
                decl.references.insert(ref)
            }
        }

        private func parseRawDeclaration(
            _ occurrence: SymbolOccurrence,
            _ usr: String,
            _ location: Location,
            _ relations: [RawRelation]
        ) -> (RawDeclaration, [RawRelation])? {
            guard let kind = transformDeclarationKind(occurrence.symbol.kind, occurrence.symbol.subkind)
            else { return nil }
            guard kind != .varParameter else {
                // Ignore indexed parameters as unused parameter identification is performed separately using SwiftSyntax.
                // Record the USR so that we can also ignore implicit accessor declarations.
                varParameterUsrs.insert(usr)
                return nil
            }

            var usr = usr

            if kind.isExtensionKind {
                // Identical extensions in different modules have the same USR, which leads to conflicts and incorrect
                // results. Here we append the module names to form a unique USR. The only references to this
                // extension will exist in the same file, so we only need a file-local mapping for the USR.
                let newUsr = "\(usr)-\(location.file.modules.sorted().joined(separator: "-"))"
                extensionUsrMap[usr] = newUsr
                usr = newUsr
            }

            let decl = RawDeclaration(
                usr: usr,
                kind: kind,
                name: occurrence.symbol.name,
                isImplicit: occurrence.roles.contains(.implicit),
                isObjcAccessible: usr.hasPrefix("c:"),
                location: location
            )

            return (decl, relations)
        }

        private func parseDeclaration(
            _ decl: Declaration,
            _ relations: [RawRelation]
        ) -> Set<Reference> {
            var references: Set<Reference> = []

            for rel in relations {
                if rel.roles.contains(.childOf) {
                    if let parentUsr = rel.symbol.usr {
                        var parentUsr = parentUsr
                        if rel.symbol.kind == .extension {
                            parentUsr = extensionUsrMap[parentUsr] ?? parentUsr
                        }
                        childDeclsByParentUsr[parentUsr, default: []].insert(decl)
                    }
                }

                if rel.roles.contains(.overrideOf) {
                    let baseFunc = rel.symbol

                    if let baseFuncUsr = baseFunc.usr, let baseFuncKind = transformDeclarationKind(baseFunc.kind, baseFunc.subKind) {
                        let reference = Reference(
                            name: baseFunc.name,
                            kind: .related,
                            declarationKind: baseFuncKind,
                            usr: baseFuncUsr,
                            location: decl.location
                        )
                        reference.parent = decl
                        decl.related.insert(reference)
                        references.insert(reference)
                    }
                }

                if !rel.roles.isDisjoint(with: [.baseOf, .calledBy, .extendedBy, .containedBy]) {
                    let referencer = rel.symbol

                    if let referencerUsr = referencer.usr {
                        for usr in decl.usrs {
                            let reference = Reference(
                                name: decl.name,
                                kind: rel.roles.contains(.baseOf) ? .related : .normal,
                                declarationKind: decl.kind,
                                usr: usr,
                                location: decl.location
                            )
                            references.insert(reference)
                            referencesByUsr[referencerUsr, default: []].insert(reference)
                        }
                    }
                }
            }

            return references
        }

        private func parseImplicit(
            _ occurrenceUsr: String,
            _ location: Location,
            _ relations: [RawRelation]
        ) -> [Reference] {
            var refs = [Reference]()

            for relation in relations {
                if relation.roles.contains(.overrideOf) {
                    let baseFunc = relation.symbol

                    if let baseFuncUsr = baseFunc.usr, let baseFuncKind = transformDeclarationKind(baseFunc.kind, baseFunc.subKind) {
                        let reference = Reference(
                            name: baseFunc.name,
                            kind: .related,
                            declarationKind: baseFuncKind,
                            usr: baseFuncUsr,
                            location: location
                        )
                        referencesByUsr[occurrenceUsr, default: []].insert(reference)
                        refs.append(reference)
                    }
                }
            }

            return refs
        }

        private func parseReference(
            _ occurrence: SymbolOccurrence,
            _ occurrenceUsr: String,
            _ location: Location,
            _ relations: [RawRelation]
        ) -> [Reference] {
            guard let kind = transformDeclarationKind(occurrence.symbol.kind, occurrence.symbol.subkind)
            else { return [] }
            guard kind != .varParameter else {
                // Ignore indexed parameters as unused parameter identification is performed separately using SwiftSyntax.
                return []
            }

            var refs = [Reference]()
            // Only these kinds carry the call role on every call site; a subscript access, for one, has none.
            let isCall = !Self.callableKinds.contains(kind) || occurrence.roles.contains(.call)

            for relation in relations {
                if !relation.roles.isDisjoint(with: [.baseOf, .calledBy, .containedBy, .extendedBy]) {
                    let referencer = relation.symbol

                    if let referencerUsr = referencer.usr {
                        let ref = Reference(
                            name: occurrence.symbol.name,
                            kind: relation.roles.contains(.baseOf) ? .related : .normal,
                            declarationKind: kind,
                            usr: occurrenceUsr,
                            location: location
                        )
                        ref.isCall = isCall
                        refs.append(ref)
                        referencesByUsr[referencerUsr, default: []].insert(ref)
                    }
                }
            }

            if refs.isEmpty {
                let ref = Reference(
                    name: occurrence.symbol.name,
                    kind: .normal,
                    declarationKind: kind,
                    usr: occurrenceUsr,
                    location: location
                )
                ref.isCall = isCall
                refs.append(ref)

                // The index store doesn't contain any relations for this reference, save it so that we can attempt
                // to associate it with the correct declaration later based on location.
                if ref.declarationKind != .module {
                    danglingReferences.append(ref)
                }
            }

            return refs
        }

        private func transformLocation(_ input: (line: Int, column: Int)) -> Location? {
            Location(file: sourceFile, line: input.line, column: input.column)
        }

        private static let callableKinds: Set<Declaration.Kind> = [
            .functionFree,
            .functionMethodInstance,
            .functionMethodStatic,
            .functionMethodClass,
            .functionConstructor,
            .functionOperator,
            .functionOperatorInfix,
            .functionOperatorPostfix,
            .functionOperatorPrefix,
        ]

        static func shouldProcessOccurrence(_ occurrence: SymbolOccurrence) -> Bool {
            occurrence.symbol.language == .swift
        }

        private func transformDeclarationKind(_ kind: SymbolKind, _ subKind: SymbolSubkind) -> Declaration.Kind? {
            switch subKind {
            case .accessorGetter: return .functionAccessorGetter
            case .accessorSetter: return .functionAccessorSetter
            case .swiftAccessorDidSet: return .functionAccessorDidset
            case .swiftAccessorWillSet: return .functionAccessorWillset
            case .swiftAccessorMutableAddressor: return .functionAccessorMutableaddress
            case .swiftAccessorAddressor: return .functionAccessorAddress
            case .swiftAccessorRead: return .functionAccessorRead
            case .swiftAccessorModify: return .functionAccessorModify
            case .swiftAccessorInit: return .functionAccessorInit
            case .swiftSubscript: return .functionSubscript
            case .swiftInfixOperator: return .functionOperatorInfix
            case .swiftPrefixOperator: return .functionOperatorPrefix
            case .swiftPostfixOperator: return .functionOperatorPostfix
            case .swiftGenericParameter: return .genericTypeParam
            case .swiftAssociatedType: return .associatedtype
            case .swiftExtensionOfClass: return .extensionClass
            case .swiftExtensionOfStruct: return .extensionStruct
            case .swiftExtensionOfProtocol: return .extensionProtocol
            case .swiftExtensionOfEnum: return .extensionEnum
            default: break
            }

            switch kind {
            case .module: return .module
            case .enum: return .enum
            case .struct: return .struct
            case .class: return .class
            case .protocol: return .protocol
            case .extension: return .extension
            case .typealias: return .typealias
            case .function: return .functionFree
            case .variable: return .varGlobal
            case .enumConstant: return .enumelement
            case .instanceMethod: return .functionMethodInstance
            case .classMethod: return .functionMethodClass
            case .staticMethod: return .functionMethodStatic
            case .instanceProperty: return .varInstance
            case .classProperty: return .varClass
            case .staticProperty: return .varStatic
            case .constructor: return .functionConstructor
            case .destructor: return .functionDestructor
            case .parameter: return .varParameter
            case .macro: return .macro
            default: return nil
            }
        }
    }
}
