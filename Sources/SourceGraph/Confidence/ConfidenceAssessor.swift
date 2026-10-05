import Configuration

/// Assesses how sure Lethen is that a reported declaration is unused, from the evidence indexing collected.
///
/// Build it after the mutators have run: the origin walk reads `graph.usedDeclarations` and memoizes its
/// answers, so a graph that changes afterwards is not seen.
public final class ConfidenceAssessor {
    private let evidence: ConfidenceEvidence
    private let graph: SourceGraph
    private let configuration: Configuration

    /// The memoized answer of `nameEvidenceOrigin(of:)`; `nil` is a declaration with no origin.
    private var nameEvidenceOrigins: [Declaration: NameEvidenceOrigin?] = [:]

    public init(evidence: ConfidenceEvidence, graph: SourceGraph, configuration: Configuration) {
        self.evidence = evidence
        self.graph = graph
        self.configuration = configuration
    }

    /// The skipped clause, in a module the declaration belongs to, that uses its name. A member or
    /// enum case is matched only by a use spelled as a member access or a call, so a bare identifier such as
    /// a local named `count` does not count.
    private func skippedBranchSite(of declaration: Declaration) -> String? {
        let baseName = SourceGraph.baseName(of: declaration.name)
        let modules = declaration.indexedModules.isEmpty ? declaration.location.file.modules : declaration.indexedModules
        return modules.compactMap { module -> String? in
            guard let sites = evidence.skippedBranches[module] else { return nil }

            if Self.spellingMatchedKinds.contains(declaration.kind), let spelled = sites.spellings[baseName] {
                return spelled.filter { canBeUse(of: declaration, spelledAs: $0.key) }.values.min()
            }
            let names = if declaration.kind == .enumelement {
                sites.constructionNames
            } else if Self.memberKinds.contains(declaration.kind) {
                sites.memberNames
            } else {
                sites.names
            }
            return names[baseName]
        }.min()
    }

    /// Kinds whose skipped uses are matched by how they are spelled, not by name alone: functions, methods and
    /// initializers by argument labels, and members by the type they are reached through.
    private static let spellingMatchedKinds: Set<Declaration.Kind> = [
        .functionFree, .functionMethodClass, .functionMethodInstance, .functionMethodStatic, .functionConstructor,
        .varClass, .varInstance, .varStatic,
    ]

    private static let functionKinds: Set<Declaration.Kind> = [
        .functionFree, .functionMethodClass, .functionMethodInstance, .functionMethodStatic, .functionConstructor,
    ]

    /// Whether a skipped use of the declaration's name, spelled this way, can be a use of this declaration. A
    /// member needs a member access or a call, as for any name. A function is matched by its labels, so that
    /// `show(title:)` does not name `show(message:)`, and a member reached through a type by that type, so that
    /// `String.init(data:)` does not name another type's initializer. Neither says anything about a use that
    /// spells no labels or no type: `#selector(show)` can be any `show`, and `self.show()` names no type.
    private func canBeUse(of declaration: Declaration, spelledAs spelling: NameSites.Spelling) -> Bool {
        if Self.memberKinds.contains(declaration.kind), !spelling.isMember { return false }

        if Self.functionKinds.contains(declaration.kind), let labels = spelling.labels,
           !Self.labels(labels, hasTrailingClosure: spelling.hasTrailingClosure, fit: Self.parameterLabels(of: declaration))
        {
            return false
        }
        if declaration.kind != .functionFree, let receiver = spelling.receiver, let enclosing = enclosingTypeDeclaration(of: declaration) {
            return !isDistinct(receiver: receiver, from: enclosing)
        }
        return true
    }

    /// The argument labels of a function's declared name, `_` for an unlabeled parameter: `["title", "_"]` for
    /// `show(title:_:)`. `nil` for a name that spells none.
    private static func parameterLabels(of declaration: Declaration) -> [String]? {
        guard let open = declaration.name.firstIndex(of: "("), declaration.name.hasSuffix(")") else { return nil }

        let inner = declaration.name[declaration.name.index(after: open) ..< declaration.name.index(before: declaration.name.endIndex)]
        return inner.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
    }

    /// Whether a call spelling `call` can be of a function that declares `parameters`: the call's labels are some
    /// of them, in order, since a parameter with a default value can be left out, and a trailing closure fills
    /// one more that the labels do not spell.
    private static func labels(_ call: [String], hasTrailingClosure: Bool, fit parameters: [String]?) -> Bool {
        guard let parameters else { return true }

        var remaining = parameters[...]
        for label in call {
            guard let index = remaining.firstIndex(of: label) else { return false }

            remaining = remaining[remaining.index(after: index)...]
        }
        return !hasTrailingClosure || call.count < parameters.count
    }

    /// Whether a use spelled through the type `receiver` cannot reach a member of `enclosing`. Only when
    /// `enclosing` is a concrete type of the scan, not a protocol whose conformers the extension's members reach, and
    /// no type of that name is a type alias of it, a subclass of it, or one of them, in either direction, since a
    /// subclass overrides what its superclass declares. A type of the scan that stands for any conforming type, a
    /// protocol, an associated type or a generic parameter, is never distinct; a name the scan does not declare is
    /// an unindexed type, which no member of the scan belongs to unless declared in an extension of it.
    private func isDistinct(receiver: String, from enclosing: Declaration) -> Bool {
        guard Self.concreteTypeKinds.contains(enclosing.kind) else { return false }

        let receivers = typeDeclarationsByName[receiver, default: []]
        guard receivers.allSatisfy({ !Self.placeholderTypeKinds.contains($0.kind) }) else { return false }

        return !receivers.contains { $0 == enclosing || typeRelatives[enclosing, default: []].contains($0) || typeRelatives[$0, default: []].contains(enclosing) }
    }

    private static let concreteTypeKinds: Set<Declaration.Kind> = [.class, .struct, .enum]
    private static let placeholderTypeKinds: Set<Declaration.Kind> = [.protocol, .associatedtype, .genericTypeParam]

    /// The type-like declarations of the scan by base name. Built on first use, after indexing.
    private lazy var typeDeclarationsByName: [String: [Declaration]] = {
        var declarations: [String: [Declaration]] = [:]
        for kind in Self.concreteTypeKinds.union(Self.placeholderTypeKinds).union([.typealias]) {
            for declaration in graph.declarations(ofKind: kind) {
                declarations[SourceGraph.baseName(of: declaration.name), default: []].append(declaration)
            }
        }
        return declarations
    }()

    /// The declarations that can stand for each type, its type aliases and subclasses, followed through each
    /// other. `typeAliasNames` finds a subclass by a reference it holds to its superclass, which the index records
    /// as a related reference, so it is not enough here. Built on first use, after indexing.
    private lazy var typeRelatives: [Declaration: Set<Declaration>] = {
        var direct: [Declaration: Set<Declaration>] = [:]
        for alias in graph.declarations(ofKind: .typealias) {
            for reference in alias.references where Self.typeKinds.contains(reference.declarationKind) {
                if let type = graph.declaration(withUsr: reference.usr) { direct[type, default: []].insert(alias) }
            }
        }
        for subclass in graph.declarations(ofKind: .class) {
            for reference in subclass.references.union(subclass.related) where reference.declarationKind == .class {
                if let superclass = graph.declaration(withUsr: reference.usr) { direct[superclass, default: []].insert(subclass) }
            }
        }

        var relatives: [Declaration: Set<Declaration>] = [:]
        for type in direct.keys {
            var closure: Set<Declaration> = []
            var pending = Array(direct[type, default: []])
            while let related = pending.popLast() {
                guard related != type, closure.insert(related).inserted else { continue }

                pending.append(contentsOf: direct[related, default: []])
            }
            relatives[type] = closure
        }
        return relatives
    }()

    /// Why a string in the scanned sources may name the declaration at run time. Only the Objective-C runtime
    /// resolves a bare string to a declaration it exposes (a selector, a class name, a key-value coding key),
    /// so a pure-Swift one counts only when a string is passed to a reflection API, or, for a class, when an
    /// Objective-C file holds the string, whose call is not read: `NSClassFromString` loads any Swift class by
    /// name, but no selector or key resolves to a pure-Swift function, member, struct, enum or protocol.
    /// A selector-shaped literal (one with a colon) names only the method whose whole selector it spells.
    private func stringLiteralReason(for declaration: Declaration) -> String? {
        let names = Self.lookupNames(of: declaration)
        let isObjcReachable = declaration.isObjcAccessible
            || declaration.attributes.contains { ["objc", "objc.name", "objcMembers", "NSManaged"].contains($0.name) }
            || declaration.modifiers.contains("dynamic")
            || declaration.usrs.contains { Self.objcName(fromUSR: $0) != nil }
        let clangTokensCount = isObjcReachable || declaration.kind == .class
        if (clangTokensCount && !evidence.clangLiteralTokens.isDisjoint(with: names))
            || (isObjcReachable && !evidence.literalTokens.isDisjoint(with: names))
        {
            return "its name appears in a string literal"
        }
        let literalSelectors = evidence.literalSelectors.union(evidence.clangLiteralSelectors)
        if isObjcReachable, !literalSelectors.isEmpty {
            if let selectors = Self.objcSelectors(of: declaration, names: names) {
                if !literalSelectors.isDisjoint(with: selectors) { return "its name appears in a string literal" }
            } else if Self.selectorKinds.contains(declaration.kind) {
                // No selector to compare with, so a literal whose first part is the name stays evidence.
                let firstParts = Set(literalSelectors.compactMap { $0.split(separator: ":").first.map(String.init) })
                if !firstParts.isDisjoint(with: names) { return "its name appears in a string literal" }
            }
        }
        return names.compactMap { evidence.reflectionSites[$0] }.min().map { "its name appears in a string passed to \($0)" }
    }

    private static let selectorKinds: Set<Declaration.Kind> = [
        .functionMethodClass, .functionMethodInstance, .functionMethodStatic, .functionConstructor,
        .varClass, .varInstance, .varStatic,
    ]

    private static let memberKinds: Set<Declaration.Kind> = [
        .functionMethodClass, .functionMethodInstance, .functionMethodStatic, .varClass, .varInstance, .varStatic, .enumelement,
    ]

    public func assess(_ declaration: Declaration) -> ConfidenceAssessment {
        // An extension is reported only with its unused type, so it is as sure as the type.
        if declaration.kind.isExtensionKind, let extended = try? graph.extendedDeclaration(forExtension: declaration), extended !== declaration {
            let assessment = assess(extended)
            if let reason = assessment.reason {
                return .init(confidence: assessment.confidence, reason: "it extends \(SourceGraph.baseName(of: extended.name)), and \(reason)")
            }
            return assessment
        }

        let objcAttributes: Set<String> = ["objc", "objc.name", "objcMembers"]
        let isObjcExposed = declaration.isObjcAccessible
            || declaration.attributes.contains { objcAttributes.contains($0.name) }
            || declaration.modifiers.contains("dynamic")

        if isObjcExposed, !configuration.retainObjcAccessible, !configuration.retainObjcAnnotated {
            switch evidence.clangCoverage {
            case nil:
                return .init(confidence: .likely, reason: "it is accessible from Objective-C, and Lethen cannot tell whether every Objective-C file of this project was indexed")
            case let coverage? where !coverage.isComplete:
                return .init(confidence: .likely, reason: coverage.confidenceReason)
            default:
                // Every Objective-C file was read, so its references are in the graph. The rules below still apply.
                break
            }
        }

        if Self.dynamicallyNamedKinds.contains(declaration.kind), let reason = stringLiteralReason(for: declaration) {
            return .init(confidence: .likely, reason: reason)
        }

        if Self.skippedBranchKinds.contains(declaration.kind),
           let site = skippedBranchSite(of: declaration)
        {
            return .init(confidence: .likely, reason: "its name appears in \(site), a branch this build did not compile")
        }

        if Self.nameEvidenceKinds.contains(declaration.kind),
           evidence.hasNameEvidence,
           let origin = nameEvidenceOrigin(of: declaration)
        {
            return .init(confidence: .likely, reason: origin.reason(isDirect: origin.declaration == declaration))
        }

        return .init(confidence: .certain, reason: nil)
    }

    /// A declaration whose name appears in code the index has no references for (a skipped `#if` clause,
    /// or a file of a target the scanned schemes do not build), or the declaration through which the
    /// reported one is reached from such a name.
    private struct NameEvidenceOrigin {
        let declaration: Declaration
        /// The declaration as the reason names it: a member with its type, `SharedWidget.init`.
        let displayName: String
        /// Where the name appears, with what that place is: `#if DEBUG at Widgets.swift:15, a branch this
        /// build did not compile`.
        let place: String

        func reason(isDirect: Bool) -> String {
            isDirect
                ? "its name appears in \(place)"
                : "it is used by \(displayName), whose name appears in \(place)"
        }
    }

    /// The declaration's base name, after its type's for a member: `SharedWidget.init`, `Store.shared`.
    private func displayName(of declaration: Declaration) -> String {
        let base = SourceGraph.baseName(of: declaration.name)
        return enclosingTypeName(of: declaration).map { "\($0).\(base)" } ?? base
    }

    /// The origin that makes `declaration` likely: code the index has no references for names it, or,
    /// failing that, an unused declaration that refers to it (or encloses one that does) has such an origin
    /// itself. The uses that code makes of what it names are not in the graph either, so a declaration
    /// only a named one uses may be used from there too.
    private func nameEvidenceOrigin(of declaration: Declaration) -> NameEvidenceOrigin? {
        if let cached = nameEvidenceOrigins[declaration] { return cached }

        var visited: Set<Declaration> = [declaration]
        let origin = nameEvidenceOrigin(of: declaration, reachedThroughReferencer: false, visited: &visited)
        nameEvidenceOrigins[declaration] = .some(origin)
        return origin
    }

    /// The step from a declaration to the one that encloses it is taken only for a declaration reached
    /// through a referencer: `SharedEntry` is used by `SharedWidget.entry`, so `SharedWidget` being named
    /// says the chain is live. For the declaration being assessed itself, its type being named says
    /// nothing about this member, which scanned code may well have left unused.
    private func nameEvidenceOrigin(of declaration: Declaration, reachedThroughReferencer: Bool, visited: inout Set<Declaration>) -> NameEvidenceOrigin? {
        if let origin = directNameEvidence(of: declaration) { return origin }

        // Only unused declarations pass the name on: a used one is used by scanned code, whatever else names it.
        for referencer in graphReferencers(of: declaration) where !graph.usedDeclarations.contains(referencer) && visited.insert(referencer).inserted {
            if let origin = nameEvidenceOrigin(of: referencer, reachedThroughReferencer: true, visited: &visited) { return origin }
        }
        if reachedThroughReferencer, let parent = declaration.parent, !graph.usedDeclarations.contains(parent), visited.insert(parent).inserted {
            return nameEvidenceOrigin(of: parent, reachedThroughReferencer: true, visited: &visited)
        }
        return nil
    }

    /// The place that names the declaration itself: a skipped `#if` clause of its module first, then a
    /// file of an unscanned target.
    private func directNameEvidence(of declaration: Declaration) -> NameEvidenceOrigin? {
        guard Self.nameEvidenceKinds.contains(declaration.kind) else { return nil }

        if Self.skippedBranchKinds.contains(declaration.kind), let site = skippedBranchSite(of: declaration) {
            return NameEvidenceOrigin(declaration: declaration, displayName: displayName(of: declaration), place: "\(site), a branch this build did not compile")
        }
        return unscannedTargetUse(of: declaration)
    }

    private func graphReferencers(of declaration: Declaration) -> [Declaration] {
        graph.references(to: declaration).compactMap(\.parent).sorted { $0.location < $1.location }
    }

    /// The smallest site of an unscanned target that names the declaration and can see it: the
    /// declaration is public or open, or sits in a file the target compiles too. An internal declaration
    /// elsewhere is not visible to the target, so a use of its name there is another declaration's.
    private func unscannedTargetUse(of declaration: Declaration) -> NameEvidenceOrigin? {
        guard Self.nameEvidenceKinds.contains(declaration.kind) else { return nil }

        let baseName = SourceGraph.baseName(of: declaration.name)
        let file = declaration.location.file.path.lexicallyNormalized()
        let enclosingType = enclosingTypeName(of: declaration)
        let aliasNames = enclosingTypeDeclaration(of: declaration).flatMap { typeAliasNames[$0] } ?? []
        var best: (site: String, target: String)?
        let modules = declaration.indexedModules.isEmpty ? declaration.location.file.modules : declaration.indexedModules
        for (target, uses) in evidence.unscannedTargets.sorted(by: { $0.key < $1.key }) {
            // Which files' names can reach the declaration: every file for a public one or one in a file the
            // target compiles too (the shared file itself is not read, so the name comes from another file,
            // where a file-scoped declaration is out of reach), and for an internal one only the files that
            // import its module with `@testable`.
            let pools: [NameSites] = if isVisibleOutsideItsModule(declaration) || (uses.sharedSourceFiles.contains(file) && isVisibleOutsideItsFile(declaration)) {
                [uses.all]
            } else if isVisibleOutsideItsFile(declaration) {
                modules.sorted().compactMap { uses.testable[$0] }
            } else {
                []
            }
            for pool in pools {
                let names = if declaration.kind == .enumelement {
                    pool.constructionNames
                } else if Self.memberKinds.contains(declaration.kind) || declaration.kind == .functionSubscript {
                    pool.memberNames
                } else {
                    pool.names
                }
                // A use spelled through the type, `Store.shared` or `Store(...)`, places the match at this type's
                // member rather than at the first use of any `shared` or `init`. A type alias names the type too.
                let typeNames = enclosingType.map { [$0] + aliasNames.sorted() } ?? []
                let qualifiedSite = typeNames.compactMap { names["\($0).\(baseName)"] }.min()
                guard let site = qualifiedSite ?? names[baseName],
                      best.map({ site < $0.site }) ?? true,
                      // A member, initializer or operator of a type is reached through the type, so a target
                      // that never names the type, nor an alias of it, uses another `init` or `shared`.
                      enclosingType == nil || typeNames.contains(where: { pool.names[$0] != nil })
                else { continue }

                best = (site, target)
            }
        }
        return best.map {
            NameEvidenceOrigin(
                declaration: declaration,
                displayName: displayName(of: declaration),
                place: "\($0.site), a file of target \($0.target), which the scanned schemes do not build"
            )
        }
    }

    /// The other names a file can reach each type's members through, by the type's base name, followed through
    /// each other: `typealias Store = AppStore` lets a file name `AppStore`'s members as `Store.shared`, and so
    /// does `typealias Shop = Store`; a class inherits the members of its superclasses, so a file that overrides
    /// `run` in a subclass of `Middle` names `Base.run` through `Middle`, which inherits `Base`. Built on first
    /// use, after indexing.
    private lazy var typeAliasNames: [Declaration: Set<String>] = {
        // Followed by declaration, not by name: two modules can each declare a `Shared`, and an alias of one
        // is not an alias of the other. Names are projected only once the closure is done. A type that is not
        // indexed, an external one, has no declaration and contributes nothing.
        var direct: [Declaration: Set<Declaration>] = [:]
        for alias in graph.declarations(ofKind: .typealias) {
            for reference in alias.references where Self.typeKinds.contains(reference.declarationKind) {
                guard let type = graph.declaration(withUsr: reference.usr) else { continue }

                direct[type, default: []].insert(alias)
            }
        }
        for subclass in graph.declarations(ofKind: .class) {
            for reference in subclass.references where reference.role == .inheritedType && reference.declarationKind == .class {
                guard let superclass = graph.declaration(withUsr: reference.usr) else { continue }

                direct[superclass, default: []].insert(subclass)
            }
        }

        var names: [Declaration: Set<String>] = [:]
        for type in direct.keys {
            var closure: Set<Declaration> = []
            var pending = Array(direct[type, default: []])
            while let alias = pending.popLast() {
                guard alias != type, closure.insert(alias).inserted else { continue }

                pending.append(contentsOf: direct[alias, default: []])
            }
            names[type] = Set(closure.map { SourceGraph.baseName(of: $0.name) })
        }
        return names
    }()

    /// The declaration of the type that declares the declaration, through any extension, or `nil` for a
    /// top-level one or one whose type is not indexed.
    private func enclosingTypeDeclaration(of declaration: Declaration) -> Declaration? {
        var current = declaration.parent
        while let parent = current {
            if Self.typeKinds.contains(parent.kind) { return parent }

            if parent.kind.isExtensionKind {
                if let extended = try? graph.extendedDeclaration(forExtension: parent) { return extended }

                // `ProtocolExtensionReferenceBuilder` replaces the extension's reference to its protocol with
                // one from the protocol to the extension.
                return graph.references(to: parent)
                    .filter { $0.declarationKind == .extensionProtocol }
                    .compactMap(\.parent)
                    .filter { $0.kind == .protocol && $0.name == parent.name }
                    .min()
            }
            current = parent.parent
        }
        return nil
    }

    /// The base name of the type that declares the declaration, through any extension, or `nil` for a
    /// top-level one.
    private func enclosingTypeName(of declaration: Declaration) -> String? {
        var current = declaration.parent
        while let parent = current {
            if parent.kind.isExtensionKind || Self.typeKinds.contains(parent.kind) {
                return SourceGraph.baseName(of: parent.name)
            }
            current = parent.parent
        }
        return nil
    }

    private static let typeKinds: Set<Declaration.Kind> = [.class, .struct, .enum, .protocol, .typealias]

    /// Whether the declaration and everything enclosing it is at least internal.
    private func isVisibleOutsideItsFile(_ declaration: Declaration) -> Bool {
        var current: Declaration? = declaration
        while let declaration = current {
            if !declaration.kind.isExtensionKind, [.private, .fileprivate].contains(declaration.accessibility.value) { return false }

            current = declaration.parent
        }
        return true
    }

    /// Whether the declaration and everything enclosing it is public or open.
    private func isVisibleOutsideItsModule(_ declaration: Declaration) -> Bool {
        var current: Declaration? = declaration
        while let declaration = current {
            // An extension's own access level is only the default of its members.
            if !declaration.kind.isExtensionKind, ![.public, .open].contains(declaration.accessibility.value) { return false }

            current = declaration.parent
        }
        return true
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

    /// Kinds a file of an unscanned target can name: the skipped-branch kinds, subscripts, which such a file
    /// spells as `store[key]`, macros, spelled `#makeWidget()`, and associated types, spelled `T.Item`.
    private static let nameEvidenceKinds = skippedBranchKinds.union([.functionSubscript, .macro, .associatedtype])

    /// The names a runtime lookup can spell for the declaration: its Swift base name, the Objective-C
    /// name of an exposed declaration when `@objc(name)` differs from it, and the setter selector of an
    /// exposed property (`setFoo` for `foo`). An initializer is reachable only by its Objective-C name
    /// (`initWithFoo`); `init` alone is not a lookup.
    static func lookupNames(of declaration: Declaration) -> Set<String> {
        var names: Set<String> = declaration.kind == .functionConstructor ? [] : [SourceGraph.baseName(of: declaration.name)]
        for usr in declaration.usrs {
            guard let name = objcName(fromUSR: usr) else { continue }

            names.insert(name)
            if declaration.kind.isVariableKind, let first = name.first {
                names.insert("set" + first.uppercased() + name.dropFirst())
            }
        }
        return names
    }

    /// The whole selectors the Objective-C runtime knows the declaration by: the selector of a method or
    /// initializer from its clang USR (`load:from:`), and the getter and setter of a property (`title`,
    /// `setTitle:`). `nil` for a kind no selector names, and for a method whose clang USR is missing, since
    /// Swift's rules for naming it depend on its labels and `@objc(name)`.
    static func objcSelectors(of declaration: Declaration, names: Set<String>) -> Set<String>? {
        if declaration.kind.isVariableKind {
            var selectors = names
            for name in names {
                if let first = name.first { selectors.insert("set" + first.uppercased() + name.dropFirst() + ":") }
            }
            return selectors
        }
        guard selectorKinds.contains(declaration.kind) else { return nil }

        let selectors = Set(declaration.usrs.compactMap { objcSelector(fromUSR: $0) })
        return selectors.isEmpty ? nil : selectors
    }

    /// The whole selector of the method, initializer or property a clang USR names: `c:objc(cs)Store(im)load:from:`
    /// is `load:from:`. `nil` for a USR that is not an Objective-C one, and for a class, protocol or category.
    static func objcSelector(fromUSR usr: String) -> String? {
        guard usr.hasPrefix("c:"), let close = usr.lastIndex(of: ")"), let open = usr[..<close].lastIndex(of: "(") else { return nil }
        guard ["im", "cm", "py", "cpy"].contains(usr[usr.index(after: open) ..< close]) else { return nil }

        let selector = usr[usr.index(after: close)...]
        return selector.isEmpty ? nil : String(selector)
    }

    /// The Objective-C name a clang USR ends with: `c:objc(cs)Store(im)load:from:` names `load`, and
    /// `c:@M@App@objc(cs)Store` names `Store`. `nil` for a USR that is not an Objective-C one.
    static func objcName(fromUSR usr: String) -> String? {
        guard usr.hasPrefix("c:"), let kind = usr.lastIndex(of: ")") else { return nil }

        let selector = usr[usr.index(after: kind)...]
        guard !selector.isEmpty else { return nil }

        return String(selector.split(separator: ":", maxSplits: 1).first ?? selector)
    }
}
