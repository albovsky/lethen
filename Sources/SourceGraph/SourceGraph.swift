import Configuration
import Foundation
import Logger
import Shared

public final class SourceGraph {
    public private(set) var allDeclarations: Set<Declaration> = []
    public private(set) var usedDeclarations: Set<Declaration> = []
    public private(set) var redundantProtocols: [Declaration: (references: Set<Reference>, inherited: Set<Reference>)] = [:]
    public private(set) var rootDeclarations: Set<Declaration> = []
    public private(set) var redundantPublicAccessibility: [Declaration: Set<String>] = [:]
    public private(set) var rootReferences: Set<Reference> = []
    public private(set) var allReferences: Set<Reference> = []
    public private(set) var retainedDeclarations: Set<Declaration> = []
    public private(set) var ignoredDeclarations: Set<Declaration> = []
    public private(set) var assetReferences: Set<AssetReference> = []
    public private(set) var mainAttributedDeclarations: Set<Declaration> = []
    public private(set) var allReferencesByUsr: [String: Set<Reference>] = [:]
    public private(set) var indexedSourceFiles: [SourceFile] = []
    public private(set) var unusedModuleImports: Set<Declaration> = []
    public private(set) var assignOnlyProperties: Set<Declaration> = []
    public private(set) var suppressedAssignOnlyProperties: Set<Declaration> = []
    public private(set) var extensions: [Declaration: Set<Declaration>] = [:]
    public private(set) var commandIgnoredDeclarations: [Declaration: CommandIgnoreKind] = [:]
    public private(set) var functionsWithIgnoredParameters: Set<Declaration> = []
    /// The mutator that retained each declaration, recorded only for `lethen explain`.
    public private(set) var retentionSources: [Declaration: String] = [:]
    /// Whether mutator runs record `retentionSources`. Off for scans, which never read them.
    public var recordsRetentionSources = false
    /// Enum cases referenced only in patterns.
    public private(set) var unconstructedEnumCases: Set<Declaration> = []
    /// Identifier-like words found in string literals across the scanned sources.
    public private(set) var literalTokens: Set<String> = []
    /// Whether the index has a unit for every C and Objective-C file the build compiled. `nil` until the
    /// pipeline records it, and for project kinds that cannot list their source files.
    public private(set) var clangCoverage: ClangCoverage?
    /// Names used in `#if` clauses this build did not compile, by the module whose file has the
    /// clause, each with the clause that uses it.
    public private(set) var skippedBranchNames: [String: [String: String]] = [:]
    /// The subset of `skippedBranchNames` used as a member access or a call.
    public private(set) var skippedBranchMemberNames: [String: [String: String]] = [:]
    /// The subset of `skippedBranchMemberNames` used outside a pattern, which is all that can construct
    /// an enum case.
    public private(set) var skippedBranchConstructionNames: [String: [String: String]] = [:]

    private var indexedModules: Set<String> = []
    private var unindexedExportedModules: Set<String> = []
    private var allDeclarationsByKind: [Declaration.Kind: Set<Declaration>] = [:]
    private var allDeclarationsByUsr: [String: Declaration] = [:]
    private var moduleToExportingModules: [String: Set<String>] = [:]

    private let configuration: Configuration
    private let logger: Logger

    public init(configuration: Configuration, logger: Logger) {
        self.configuration = configuration
        self.logger = logger
    }

    public func setClangCoverage(_ coverage: ClangCoverage?) {
        clangCoverage = coverage
    }

    public func addLiteralTokens(_ tokens: Set<String>) {
        literalTokens.formUnion(tokens)
    }

    public func addSkippedBranchNames(_ names: [String: String], members: [String: String], construction: [String: String], modules: Set<String>) {
        for module in modules {
            skippedBranchNames[module, default: [:]].merge(names) { min($0, $1) }
            skippedBranchMemberNames[module, default: [:]].merge(members) { min($0, $1) }
            skippedBranchConstructionNames[module, default: [:]].merge(construction) { min($0, $1) }
        }
    }

    /// The skipped clause, in a module the declaration belongs to, that uses its name. A member or
    /// enum case is matched only by a use spelled as a member access or a call, so a bare identifier such as
    /// a local named `count` does not count.
    private func skippedBranchSite(of declaration: Declaration) -> String? {
        let names = if declaration.kind == .enumelement {
            skippedBranchConstructionNames
        } else if Self.memberKinds.contains(declaration.kind) {
            skippedBranchMemberNames
        } else {
            skippedBranchNames
        }
        let baseName = Self.baseName(of: declaration.name)
        let modules = declaration.indexedModules.isEmpty ? declaration.location.file.modules : declaration.indexedModules
        return modules.compactMap { names[$0]?[baseName] }.min()
    }

    private static let memberKinds: Set<Declaration.Kind> = [
        .functionMethodClass, .functionMethodInstance, .functionMethodStatic, .varClass, .varInstance, .varStatic, .enumelement,
    ]

    public func assessConfidence(of declaration: Declaration) -> ConfidenceAssessment {
        let objcAttributes: Set<String> = ["objc", "objc.name", "objcMembers"]
        let isObjcExposed = declaration.isObjcAccessible
            || declaration.attributes.contains { objcAttributes.contains($0.name) }
            || declaration.modifiers.contains("dynamic")

        if isObjcExposed, !configuration.retainObjcAccessible, !configuration.retainObjcAnnotated {
            switch clangCoverage {
            case nil:
                return .init(confidence: .likely, reason: "it is accessible from Objective-C, and Lethen cannot tell whether every Objective-C file of this project was indexed")
            case let coverage? where !coverage.isComplete:
                return .init(confidence: .likely, reason: coverage.confidenceReason)
            default:
                // Every Objective-C file was read, so its references are in the graph. The rules below still apply.
                break
            }
        }

        if Self.dynamicallyNamedKinds.contains(declaration.kind),
           !literalTokens.isDisjoint(with: Self.lookupNames(of: declaration))
        {
            return .init(confidence: .likely, reason: "its name appears in a string literal")
        }

        if Self.skippedBranchKinds.contains(declaration.kind),
           let site = skippedBranchSite(of: declaration)
        {
            return .init(confidence: .likely, reason: "its name appears in \(site), a branch this build did not compile")
        }

        return .init(confidence: .certain, reason: nil)
    }

    /// Kinds a runtime lookup by name can reach: types, methods, properties, and enum cases. Not
    /// parameters, locals, imports, or extensions.
    private static let dynamicallyNamedKinds: Set<Declaration.Kind> = [
        .class, .struct, .enum, .protocol, .enumelement,
        .functionFree, .functionMethodClass, .functionMethodInstance, .functionMethodStatic, .functionConstructor,
        .varClass, .varGlobal, .varInstance, .varStatic,
    ]

    /// Kinds a use in a skipped branch can be the only use of: the runtime-named kinds, type aliases, and operators.
    private static let skippedBranchKinds = dynamicallyNamedKinds.union([
        .typealias, .functionOperator, .functionOperatorInfix, .functionOperatorPrefix, .functionOperatorPostfix,
    ])

    /// The names a runtime lookup can spell for the declaration: its Swift base name, the Objective-C
    /// name of an exposed declaration when `@objc(name)` differs from it, and the setter selector of an
    /// exposed property (`setFoo` for `foo`). An initializer is reachable only by its Objective-C name
    /// (`initWithFoo`); `init` alone is not a lookup.
    static func lookupNames(of declaration: Declaration) -> Set<String> {
        var names: Set<String> = declaration.kind == .functionConstructor ? [] : [baseName(of: declaration.name)]
        for usr in declaration.usrs {
            guard let name = objcName(fromUSR: usr) else { continue }

            names.insert(name)
            if declaration.kind.isVariableKind, let first = name.first {
                names.insert("set" + first.uppercased() + name.dropFirst())
            }
        }
        return names
    }

    /// The Objective-C name a clang USR ends with: `c:objc(cs)Store(im)load:from:` names `load`, and
    /// `c:@M@App@objc(cs)Store` names `Store`. `nil` for a USR that is not an Objective-C one.
    static func objcName(fromUSR usr: String) -> String? {
        guard usr.hasPrefix("c:"), let kind = usr.lastIndex(of: ")") else { return nil }

        let selector = usr[usr.index(after: kind)...]
        guard !selector.isEmpty else { return nil }

        return String(selector.split(separator: ":", maxSplits: 1).first ?? selector)
    }

    /// The name without argument labels: `load(from:)` becomes `load`.
    public static func baseName(of name: String) -> String {
        name.split(separator: "(", maxSplits: 1).first.map(String.init) ?? name
    }

    public func indexingComplete() {
        rootDeclarations = allDeclarations.filter { $0.parent == nil }
        rootReferences = allReferences.filter { $0.parent == nil }
        unindexedExportedModules = Set(moduleToExportingModules.keys).subtracting(indexedModules)
    }

    public var unusedDeclarations: Set<Declaration> {
        allDeclarations.subtracting(usedDeclarations)
    }

    public func declarations(ofKind kind: Declaration.Kind) -> Set<Declaration> {
        allDeclarationsByKind[kind] ?? []
    }

    public func declarations(ofKinds kinds: Set<Declaration.Kind>) -> Set<Declaration> {
        declarations(ofKinds: Array(kinds))
    }

    public func declarations(ofKinds kinds: [Declaration.Kind]) -> Set<Declaration> {
        kinds.flatMapSet { allDeclarationsByKind[$0, default: []] }
    }

    public func declaration(withUsr usr: String) -> Declaration? {
        allDeclarationsByUsr[usr]
    }

    public func references(to decl: Declaration) -> Set<Reference> {
        decl.usrs.flatMapSet { references(to: $0) }
    }

    public func references(to usr: String) -> Set<Reference> {
        allReferencesByUsr[usr, default: []]
    }

    public func hasReferences(to decl: Declaration) -> Bool {
        decl.usrs.contains { !allReferencesByUsr[$0, default: []].isEmpty }
    }

    func markRedundantProtocol(_ declaration: Declaration, references: Set<Reference>, inherited: Set<Reference>) {
        redundantProtocols[declaration] = (references, inherited)
    }

    func markRedundantPublicAccessibility(_ declaration: Declaration, modules: Set<String>) {
        redundantPublicAccessibility[declaration] = modules
    }

    func unmarkRedundantPublicAccessibility(_ declaration: Declaration) {
        _ = redundantPublicAccessibility.removeValue(forKey: declaration)
    }

    func markIgnored(_ declaration: Declaration) {
        _ = ignoredDeclarations.insert(declaration)
    }

    public func markCommandIgnored(_ declaration: Declaration, kind: CommandIgnoreKind) {
        commandIgnoredDeclarations[declaration] = kind
    }

    public func markHasIgnoredParameters(_ declaration: Declaration) {
        _ = functionsWithIgnoredParameters.insert(declaration)
    }

    public func markRetained(_ declaration: Declaration) {
        if let parent = declaration.parent {
            for usr in declaration.usrs {
                let reference = Reference(
                    name: declaration.name,
                    kind: .retained,
                    declarationKind: declaration.kind,
                    usr: usr,
                    location: declaration.location
                )
                reference.parent = parent
                add(reference, from: parent)
            }
        } else {
            _ = retainedDeclarations.insert(declaration)
        }
    }

    func unmarkRetained(_ declaration: Declaration) {
        retainedDeclarations.remove(declaration)

        let retainedReferences = declaration.usrs.flatMapSet { usr in
            allReferencesByUsr[usr, default: []]
        }.filter { reference in
            reference.kind == .retained && reference.parent === declaration.parent
        }

        for reference in retainedReferences {
            remove(reference)
        }
    }

    public func markRetained(_ declarations: Set<Declaration>) {
        declarations.forEach { markRetained($0) }
    }

    func markUnconstructedEnumCase(_ declaration: Declaration) {
        _ = unconstructedEnumCases.insert(declaration)
    }

    func markAssignOnlyProperty(_ declaration: Declaration) {
        _ = assignOnlyProperties.insert(declaration)
    }

    func markSuppressedAssignOnlyProperty(_ declaration: Declaration) {
        _ = suppressedAssignOnlyProperties.insert(declaration)
    }

    func markMainAttributed(_ declaration: Declaration) {
        _ = mainAttributedDeclarations.insert(declaration)
    }

    public func isRetained(_ declaration: Declaration) -> Bool {
        retainedDeclarations.contains(declaration) || references(to: declaration).contains { $0.kind == .retained }
    }

    /// Whether `PubliclyAccessibleRetainer` retains the declaration: it is public or open, `--retain-public` is set
    /// or its module is listed in `--retain-public-targets`, and it has no `_spi` group listed in `--no-retain-spi`.
    public func isRetainedPublicAPI(_ declaration: Declaration) -> Bool {
        guard declaration.accessibility.value == .public || declaration.accessibility.value == .open else { return false }

        let isRetainedModule = configuration.retainPublic
            || !declaration.location.file.modules.isDisjoint(with: configuration.retainPublicTargets)
        guard isRetainedModule else { return false }
        guard !configuration.noRetainSPI.isEmpty else { return true }

        return !declaration.attributes.contains { attribute in
            guard attribute.name == "_spi", let group = attribute.arguments else { return false }

            return configuration.noRetainSPI.contains(group)
        }
    }

    public func add(_ declaration: Declaration) {
        allDeclarations.insert(declaration)
        allDeclarationsByKind[declaration.kind, default: []].insert(declaration)
        for usr in declaration.usrs {
            if let existingDecl = allDeclarationsByUsr[usr] {
                logger.warn("""
                Declaration conflict detected: a declaration with the USR '\(usr)' has already been indexed.
                This issue can cause inconsistent and incorrect results.
                Existing declaration: \(existingDecl), declared in modules: \(existingDecl.location.file.modules.sorted())
                Conflicting declaration: \(declaration), declared in modules: \(declaration.location.file.modules.sorted())
                To resolve this warning, make sure all build modules are uniquely named.
                """)
                // Keep the declaration that sorts first to ensure deterministic results
                // regardless of indexing order.
                if declaration < existingDecl {
                    allDeclarationsByUsr[usr] = declaration
                }
            } else {
                allDeclarationsByUsr[usr] = declaration
            }
        }
    }

    public func add(_ declarations: Set<Declaration>) {
        declarations.forEach { add($0) }
    }

    public func remove(_ declaration: Declaration) {
        declaration.parent?.declarations.remove(declaration)
        allDeclarations.remove(declaration)
        allDeclarationsByKind[declaration.kind]?.remove(declaration)
        rootDeclarations.remove(declaration)
        usedDeclarations.remove(declaration)
        assignOnlyProperties.remove(declaration)
        suppressedAssignOnlyProperties.remove(declaration)
        // A conflicting declaration can own the USR; removing this one must not unmap it.
        for usr in declaration.usrs where allDeclarationsByUsr[usr] === declaration {
            allDeclarationsByUsr.removeValue(forKey: usr)
        }
    }

    public func add(_ reference: Reference) {
        _ = allReferences.insert(reference)
        allReferencesByUsr[reference.usr, default: []].insert(reference)
    }

    /// Adds a reference from top-level code, which has no declaration to hold it, after `indexingComplete`.
    public func addRoot(_ reference: Reference) {
        add(reference)
        _ = rootReferences.insert(reference)
    }

    public func add(_ references: Set<Reference>) {
        allReferences.formUnion(references)
        references.forEach { allReferencesByUsr[$0.usr, default: []].insert($0) }
    }

    public func add(_ reference: Reference, from declaration: Declaration) {
        if reference.kind == .related {
            _ = declaration.related.insert(reference)
        } else {
            _ = declaration.references.insert(reference)
        }

        add(reference)
    }

    func remove(_ reference: Reference) {
        _ = allReferences.remove(reference)
        allReferences.subtract(reference.descendentReferences)
        allReferencesByUsr[reference.usr]?.remove(reference)

        if let parent = reference.parent {
            parent.references.remove(reference)
            parent.related.remove(reference)
        }
    }

    public func add(_ assetReference: AssetReference) {
        _ = assetReferences.insert(assetReference)
    }

    func recordRetentionSource(_ source: String, for declarations: Set<Declaration>) {
        for declaration in declarations where retentionSources[declaration] == nil {
            retentionSources[declaration] = source
        }
    }

    func markUsed(_ declaration: Declaration) {
        _ = usedDeclarations.insert(declaration)
    }

    func isUsed(_ declaration: Declaration) -> Bool {
        usedDeclarations.contains(declaration)
    }

    func isExternal(_ reference: Reference) -> Bool {
        declaration(withUsr: reference.usr) == nil
    }

    public func addIndexedSourceFile(_ file: SourceFile) {
        indexedSourceFiles.append(file)
    }

    public func addIndexedModules(_ modules: Set<String>) {
        indexedModules.formUnion(modules)
    }

    public func isModuleIndexed(_ module: String) -> Bool {
        indexedModules.contains(module)
    }

    public func addExportedModule(_ module: String, exportedBy exportingModules: Set<String>) {
        moduleToExportingModules[module, default: []].formUnion(exportingModules)
    }

    public func moduleExportsUnindexedModules(_ module: String) -> Bool {
        unindexedExportedModules.contains { unindexedModule in
            isModule(unindexedModule, exportedBy: module)
        }
    }

    public func isModule(_ module: String, exportedBy exportingModule: String) -> Bool {
        let exportingModules = moduleToExportingModules[module, default: []]

        if exportingModules.contains(exportingModule) {
            // The module is exported directly.
            return true
        }

        // Recursively check if the module is exported transitively.
        return exportingModules.contains { nestedExportingModule in
            isModule(nestedExportingModule, exportedBy: exportingModule) &&
                isModule(module, exportedBy: nestedExportingModule)
        }
    }

    func markUnusedModuleImport(_ statement: ImportStatement) {
        let location = statement.location.relativeTo(configuration.projectRoot)
        let usr = "import-\(statement.qualifiedModule)-\(location)"
        let decl = Declaration(name: statement.qualifiedModule, kind: .module, usrs: [usr], location: statement.location)
        unusedModuleImports.insert(decl)
    }

    func markExtension(_ extensionDecl: Declaration, extending extendedDecl: Declaration) {
        _ = extensions[extendedDecl, default: []].insert(extensionDecl)
    }

    func inheritedTypeReferences(of decl: Declaration, seenDeclarations: Set<Declaration> = []) -> Set<Reference> {
        var references = Set<Reference>()

        for reference in decl.immediateInheritedTypeReferences {
            references.insert(reference)

            if let inheritedDecl = declaration(withUsr: reference.usr) {
                // Detect circular references. The following is valid Swift.
                // class SomeClass {}
                // extension SomeClass: SomeProtocol {}
                // protocol SomeProtocol: SomeClass {}
                guard !seenDeclarations.contains(inheritedDecl) else { continue }

                references = inheritedTypeReferences(of: inheritedDecl, seenDeclarations: seenDeclarations.union([decl])).union(references)
            }
        }

        return references
    }

    func inheritedDeclarations(of decl: Declaration) -> [Declaration] {
        inheritedTypeReferences(of: decl).compactMap { declaration(withUsr: $0.usr) }
    }

    func immediateSubclasses(of decl: Declaration) -> Set<Declaration> {
        references(to: decl)
            .filter { $0.kind == .related && $0.declarationKind == .class }
            .flatMap { $0.parent?.usrs ?? [] }
            .compactMapSet { declaration(withUsr: $0) }
    }

    func subclasses(of decl: Declaration) -> Set<Declaration> {
        let immediate = immediateSubclasses(of: decl)
        let allSubclasses = immediate.flatMapSet { subclasses(of: $0) }
        return immediate.union(allSubclasses)
    }

    func extendedDeclarationReference(forExtension extensionDeclaration: Declaration) throws -> Reference? {
        guard let extendedKind = extensionDeclaration.kind.extendedKind else {
            throw LethenError.sourceGraphIntegrityError(message: "Unknown extended reference kind for extension '\(extensionDeclaration.kind.rawValue)'")
        }

        return extensionDeclaration.references
            .filter { $0.declarationKind == extendedKind && $0.name == extensionDeclaration.name }
            .min()
    }

    func extendedDeclaration(forExtension extensionDeclaration: Declaration) throws -> Declaration? {
        guard let extendedReference = try extendedDeclarationReference(forExtension: extensionDeclaration) else { return nil }

        if let extendedDeclaration = declaration(withUsr: extendedReference.usr) {
            return extendedDeclaration
        }

        return nil
    }

    func allSuperDeclarationsInOverrideChain(from decl: Declaration) -> Set<Declaration> {
        guard decl.isOverride else { return [] }

        let overridenDecl = decl.related
            .filter { $0.declarationKind == decl.kind && $0.name == decl.name }
            .compactMap { declaration(withUsr: $0.usr) }
            .min()

        guard let overridenDecl else {
            return []
        }

        return Set([overridenDecl]).union(allSuperDeclarationsInOverrideChain(from: overridenDecl))
    }

    func baseDeclaration(fromOverride decl: Declaration) -> (Declaration, Bool) {
        guard decl.isOverride else { return (decl, true) }

        let baseDecl = references(to: decl)
            .filter {
                $0.kind == .related &&
                    $0.declarationKind == decl.kind &&
                    $0.name == decl.name
            }
            .compactMap(\.parent)
            .min()

        guard let baseDecl else {
            // Base reference is external, return the current function as it's the closest.
            return (decl, false)
        }

        return baseDeclaration(fromOverride: baseDecl)
    }

    func allOverrideDeclarations(fromBase decl: Declaration) -> Set<Declaration> {
        decl.relatedEquivalentReferences
            .compactMap { declaration(withUsr: $0.usr) }
            .reduce(into: .init()) { result, decl in
                guard decl.isOverride else { return }

                result.insert(decl)
                result.formUnion(allOverrideDeclarations(fromBase: decl))
            }
    }

    func isCodable(_ decl: Declaration) -> Bool {
        let codableTypes = ["Codable", "Decodable", "Encodable"] + configuration.externalEncodableProtocols + configuration.externalCodableProtocols

        return inheritedTypeReferences(of: decl).contains {
            [.protocol, .typealias].contains($0.declarationKind) && codableTypes.contains($0.name)
        }
    }

    func isEncodable(_ decl: Declaration) -> Bool {
        let encodableTypes = ["Encodable"] + configuration.externalEncodableProtocols + configuration.externalCodableProtocols

        return inheritedTypeReferences(of: decl).contains {
            [.protocol, .typealias].contains($0.declarationKind) && encodableTypes.contains($0.name)
        }
    }

    func isDecodable(_ decl: Declaration) -> Bool {
        let decodableTypes = ["Decodable"] + configuration.externalCodableProtocols

        return inheritedTypeReferences(of: decl).contains {
            [.protocol, .typealias].contains($0.declarationKind) && decodableTypes.contains($0.name)
        }
    }

    func isRawRepresentable(_ enumDeclaration: Declaration) -> Bool {
        // If the enum has a related struct it's very likely to be raw representable,
        // and thus is dynamic in nature.

        if enumDeclaration.related.contains(where: { $0.declarationKind == .struct }) {
            return true
        }

        return inheritedTypeReferences(of: enumDeclaration).contains {
            $0.declarationKind == .protocol && $0.name == "RawRepresentable"
        }
    }

    func isEquatable(_ decl: Declaration) -> Bool {
        let equatableTypes = ["Equatable", "Hashable"]

        return inheritedTypeReferences(of: decl).contains {
            [.protocol, .typealias].contains($0.declarationKind) && equatableTypes.contains($0.name)
        }
    }

    func isHashable(_ decl: Declaration) -> Bool {
        inheritedTypeReferences(of: decl).contains {
            [.protocol, .typealias].contains($0.declarationKind) && $0.name == "Hashable"
        }
    }
}
