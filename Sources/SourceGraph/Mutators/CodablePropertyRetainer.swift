import Configuration
import Foundation
import Shared

final class CodablePropertyRetainer: SourceGraphMutator {
    private static let encodableUsrs: Set<String> = ["s:SE", "s:s7Codablea"]
    private static let decodableUsrs: Set<String> = ["s:Se", "s:s7Codablea"]

    private let graph: SourceGraph
    private let configuration: Configuration
    private lazy var typealiasesByName: [String: [Declaration]] = Dictionary(grouping: graph.declarations(ofKind: .typealias), by: \.name)

    required init(graph: SourceGraph, configuration: Configuration, swiftVersion _: SwiftVersion) {
        self.graph = graph
        self.configuration = configuration
    }

    func mutate() {
        if !configuration.retainCodableProperties, !configuration.retainEncodableProperties {
            buildSynthesizedEncodeReads()
        }

        if !configuration.retainCodableProperties {
            buildSynthesizedDecodeReads()
        }

        if configuration.retainCodableProperties {
            for decl in graph.declarations(ofKinds: Declaration.Kind.discreteConformableKinds) {
                guard graph.isCodable(decl) else { continue }

                for decl in decl.declarations {
                    guard decl.kind == .varInstance else { continue }

                    graph.markRetained(decl)
                }
            }
        } else if configuration.retainEncodableProperties {
            for decl in graph.declarations(ofKinds: Declaration.Kind.discreteConformableKinds) {
                guard graph.isEncodable(decl) else { continue }

                for decl in decl.declarations {
                    guard decl.kind == .varInstance else { continue }

                    graph.markRetained(decl)
                }
            }
        }
    }

    /// Synthesized `encode(to:)` reads every stored property. Model that read only where a whole
    /// value reaches a call that may encode it: a function whose parameter is constrained to
    /// `Encodable` or is an `Encodable` existential. For an indexed function that comes from its
    /// references; for an unindexed one, such as `JSONEncoder.encode(_:)` or the encoding containers'
    /// `encode` methods, from its mangled USR. Other unindexed calls, such as `Array.append(_:)` or
    /// `print(_:)`, are not evidence.
    private func buildSynthesizedEncodeReads() {
        var synthesizedTypes: Set<Declaration> = []
        // A class is covered like a struct; a subclass of an Encodable class is not, as Swift does not
        // synthesize `encode(to:)` for it.
        for type in graph.declarations(ofKinds: [.struct, .class]) {
            guard graph.isEncodable(type), !hasEncodableSuperclass(type), !inheritsCustomEncoder(type), !hasProtocolExtensionEncoder(type) else { continue }

            let extensions = graph.extensions[type] ?? []
            let members = type.declarations.union(extensions.flatMap(\.declarations))
            guard !members.contains(where: { isCustomCoder($0, named: "encode(to:)", parameterType: "Encoder") }) else { continue }

            synthesizedTypes.insert(type)
        }

        for use in graph.allReferences where use.kind == .normal && !use.valueArgumentReferences.isEmpty {
            guard let caller = use.parent, !caller.isImplicit else { continue }

            let mayEncode = if let callee = graph.declaration(withUsr: use.usr) {
                mayEncode(indexed: callee)
            } else {
                Self.mayEncode(unindexedUsr: use.usr)
            }
            guard mayEncode else { continue }

            markEncodedReads(from: use, caller: caller, synthesizedTypes: synthesizedTypes)
        }
    }

    /// A class that declares `Encodable` but inherits `encode(to:)` from a superclass that does not conform
    /// uses that method as its witness, so nothing is synthesized.
    private func inheritsCustomEncoder(_ type: Declaration, seen: Set<Declaration> = []) -> Bool {
        for reference in type.immediateInheritedTypeReferences where reference.declarationKind == .class {
            guard let superclass = graph.declaration(withUsr: reference.usr), !seen.contains(superclass) else { continue }

            let members = superclass.declarations.union((graph.extensions[superclass] ?? []).flatMap(\.declarations))
            // A private or fileprivate method is not inherited, so it is not the subclass's witness.
            if members.contains(where: { isInheritableCustomEncoder($0) })
                || inheritsCustomEncoder(superclass, seen: seen.union([type]))
            {
                return true
            }
        }
        return false
    }

    private func isInheritableCustomEncoder(_ member: Declaration) -> Bool {
        guard isCustomCoder(member, named: "encode(to:)", parameterType: "Encoder") else { return false }

        return ![.private, .fileprivate].contains(member.accessibility.value)
    }

    /// An `encode(to:)` supplied by an extension of a protocol the type conforms to, such as
    /// `protocol P: Encodable {}` with `extension P { func encode(to:) }`, is the witness, so nothing is
    /// synthesized. The members read are those of the protocol's extension declarations, which
    /// `ProtocolExtensionReferenceBuilder` links from the protocol declaration and does not fold into it.
    private func hasProtocolExtensionEncoder(_ type: Declaration) -> Bool {
        graph.inheritedTypeReferences(of: type).contains { reference in
            guard reference.declarationKind == .protocol, let proto = graph.declaration(withUsr: reference.usr) else { return false }

            return proto.references.contains { extensionReference in
                guard extensionReference.declarationKind == .extensionProtocol,
                      let extensionDeclaration = graph.declaration(withUsr: extensionReference.usr) else { return false }

                return extensionDeclaration.declarations.contains { isCustomCoder($0, named: "encode(to:)", parameterType: "Encoder") }
            }
        }
    }

    private func hasEncodableSuperclass(_ type: Declaration) -> Bool {
        type.immediateInheritedTypeReferences.contains { reference in
            guard reference.declarationKind == .class, let superclass = graph.declaration(withUsr: reference.usr) else { return false }

            return graph.isEncodable(superclass)
        }
    }

    private func mayEncode(indexed callee: Declaration) -> Bool {
        callee.references.contains { reference in
            switch reference.role {
            case .genericParameterType, .genericRequirementType:
                Self.encodableUsrs.contains(reference.usr)
                    || graph.declaration(withUsr: reference.usr).map { graph.isEncodable($0) } == true
            case .parameterType:
                // Only an existential parameter; a concrete Encodable type is not evidence.
                Self.encodableUsrs.contains(reference.usr)
                    || graph.declaration(withUsr: reference.usr).map { $0.kind == .protocol && graph.isEncodable($0) } == true
            default:
                false
            }
        }
    }

    /// A parameter constrained to `Encodable` (`…SERz…`, `…SERd__…`) or an `Encodable` existential (`SE_`),
    /// in Swift's mangling of the callee's signature.
    private static func mayEncode(unindexedUsr usr: String) -> Bool {
        usr.range(of: "SE(R[zd]|_)", options: .regularExpression) != nil
    }

    private func markEncodedReads(from use: Reference, caller: Declaration, synthesizedTypes: Set<Declaration>) {
        // Synthesized encoding writes every stored property, including a constant with an initial value.
        // An explicit CodingKeys enum limits the encoded properties, as it does the decoded ones.
        let classify: (Declaration, Declaration) -> PropertyUse = { [self] type, property in
            guard !property.isImplicit, !property.hasAccessorBody, !isOmittedByCodingKeys(property, in: type) else { return .skip }

            return .read
        }
        markReads(from: use, caller: caller, synthesizedTypes: synthesizedTypes, referencedBy: use.valueArgumentReferences, classify: classify)
    }

    /// Synthesized `init(from:)` requires every non-optional stored property to be present in the
    /// decoded value (`decode`), so removing one relaxes response-shape validation. Model that only
    /// where a type reaches a call that may decode it, as for encoding, and only for properties the
    /// synthesized initializer decodes with `decode`: optional properties use `decodeIfPresent`, and a
    /// nested `CodingKeys` enum restricts the decoded set to its cases. Writing a custom `init(from:)`
    /// opts out, and its writes are indexed normally. `--retain-codable-properties` retains every property.
    private func buildSynthesizedDecodeReads() {
        var synthesizedTypes: Set<Declaration> = []
        for type in graph.declarations(ofKind: .struct) {
            guard graph.isDecodable(type) else { continue }

            let extensions = graph.extensions[type] ?? []
            let members = type.declarations.union(extensions.flatMap(\.declarations))
            guard !members.contains(where: { isCustomCoder($0, named: "init(from:)", parameterType: "Decoder") }) else { continue }

            synthesizedTypes.insert(type)
        }

        guard !synthesizedTypes.isEmpty else { return }

        let decodableNames = decodableProtocolNames
        let classifyDecode: (Declaration, Declaration) -> PropertyUse = { [self] type, property in decodeUse(of: property, in: type) }

        for use in graph.allReferences where use.kind == .normal && !use.valueArguments.isEmpty {
            // A use with no parent is top-level code, which holds its reads as root references.
            let caller = use.parent
            guard caller?.isImplicit != true else { continue }

            let decoded: Set<Reference>
            if let callee = graph.declaration(withUsr: use.usr) {
                guard mayDecode(indexed: callee) else { continue }

                decoded = decodedArguments(of: use, callee: callee, decodableNames: decodableNames)
            } else {
                guard Self.mayDecode(unindexedUsr: use.usr) else { continue }

                // Without the callee's parameter types, only the standard decoding APIs are known to decode
                // their first argument, the metatype. Any other callee is not evidence.
                guard Self.isStandardDecodingCall(usr: use.usr), let metatype = use.valueArguments.first, metatype.label == nil else { continue }

                decoded = metatype.references
            }
            guard !decoded.isEmpty else { continue }

            markReads(from: use, caller: caller, synthesizedTypes: synthesizedTypes, referencedBy: withGenericArguments(decoded, classify: classifyDecode), classify: classifyDecode)
        }
    }

    /// The names that make a parameter decode its argument: `Decodable`, the protocols that inherit it,
    /// and the configured external ones.
    private var decodableProtocolNames: Set<String> {
        var names: Set<String> = ["Decodable", "Codable"]
        names.formUnion(configuration.externalCodableProtocols)
        for decl in graph.declarations(ofKind: .protocol) where graph.isDecodable(decl) {
            names.insert(decl.name)
        }
        return names
    }

    /// Only the arguments passed for a parameter constrained to `Decodable` or typed as a `Decodable` existential are
    /// decoded. An argument for another parameter, such as the metatype of an unconstrained generic parameter in the
    /// same call, is not evidence. The call's labels are matched to the callee's parameters in order, skipping
    /// parameters left to their defaults; a call that cannot be matched yields nothing.
    private func decodedArguments(of use: Reference, callee: Declaration, decodableNames: Set<String>) -> Set<Reference> {
        let parameters = callee.parameterTypeNames
        var decoded: Set<Reference> = []
        var index = 0
        var variadic: Int?
        for argument in use.valueArguments {
            // Only the first argument of a variadic parameter carries its label; the rest follow unlabeled.
            if let current = variadic, argument.label == nil {
                if !parameters[current].names.isDisjoint(with: decodableNames) {
                    decoded.formUnion(argument.references)
                }
                continue
            }
            variadic = nil

            while index < parameters.count, parameters[index].label != argument.label {
                index += 1
            }
            guard index < parameters.count else { return [] }

            if !parameters[index].names.isDisjoint(with: decodableNames) {
                decoded.formUnion(argument.references)
            }
            if parameters[index].isVariadic {
                variadic = index
            }
            index += 1
        }
        return decoded
    }

    /// An explicit `encode(to:)` or `init(from:)` replaces the synthesized one only when its parameter is the
    /// coder: an overload such as `init(from number: Int)` leaves the synthesized initializer in place. A parameter
    /// whose type is unknown counts as the coder.
    private func isCustomCoder(_ member: Declaration, named name: String, parameterType: String) -> Bool {
        guard member.name == name, !member.isImplicit else { return false }
        guard let declaredType = member.parameterTypeNames.first?.typeName else { return true }

        var type = declaredType.trimmingCharacters(in: .whitespaces)
        for prefix in ["any ", "Swift."] where type.hasPrefix(prefix) {
            type.removeFirst(prefix.count)
        }
        // A typealias of the coder is still the coder. Any other type, including an alias of one, is an unrelated
        // overload. An alias that cannot be resolved counts as the coder.
        if type == parameterType {
            return true
        }
        // A qualified spelling such as `Namespace.Alias` names the alias by its last component; the qualifier must
        // be the type that declares it.
        let components = type.split(separator: ".").map(String.init)
        let qualifier = components.count > 1 ? components[components.count - 2] : nil
        let candidates = typealiasesByName[components.last ?? type] ?? []
        guard !candidates.isEmpty else { return false }

        if let qualifier {
            let declared = candidates.filter { $0.parent?.name == qualifier }
            guard declared.count == 1, let alias = declared.first else { return true }
            guard let target = resolveTypealias(alias) else { return true }

            return target.name == parameterType
        }

        // Resolve the spelled name by scope: the enclosing type and its extensions, then the scopes outward, then the
        // module. Two aliases at the same level, or none in scope, cannot be told apart and count as the coder.
        var scope = member.parent
        while true {
            let holders = scope.map { [$0] + (graph.extensions[$0] ?? []) } ?? []
            let found = candidates.filter { alias in scope == nil ? alias.parent == nil : alias.parent.map(holders.contains) == true }
            if found.count > 1 {
                return true
            }
            if let alias = found.first {
                guard let target = resolveTypealias(alias) else { return true }

                return target.name == parameterType
            }
            guard let outer = scope else { return true }

            scope = outer.parent
        }
    }

    /// Follows a typealias through any chain of typealiases to the type it finally names, with cycles and
    /// aliases of more than one type reported as unresolvable.
    private func resolveTypealias(_ alias: Declaration) -> (name: String, declaration: Declaration?)? {
        var current = alias
        var visited: Set<Declaration> = []
        while visited.insert(current).inserted {
            let targets = current.references.filter {
                $0.kind == .normal && [.enum, .struct, .class, .protocol, .typealias, .associatedtype].contains($0.declarationKind)
            }
            guard targets.count == 1, let target = targets.first else { return nil }

            if let next = graph.declaration(withUsr: target.usr), next.kind == .typealias {
                current = next
                continue
            }

            return (target.name, graph.declaration(withUsr: target.usr))
        }
        return nil
    }

    private func mayDecode(indexed callee: Declaration) -> Bool {
        callee.references.contains { reference in
            switch reference.role {
            case .genericParameterType, .genericRequirementType:
                Self.decodableUsrs.contains(reference.usr)
                    || configuration.externalCodableProtocols.contains(reference.name)
                    || graph.declaration(withUsr: reference.usr).map { graph.isDecodable($0) } == true
            case .parameterType:
                // Only an existential parameter; a concrete Decodable type is not evidence.
                Self.decodableUsrs.contains(reference.usr)
                    || (reference.declarationKind == .protocol && configuration.externalCodableProtocols.contains(reference.name))
                    || graph.declaration(withUsr: reference.usr).map { $0.kind == .protocol && graph.isDecodable($0) } == true
            default:
                false
            }
        }
    }

    /// A parameter constrained to `Decodable` (`…SeRz…`, `…SeRd__…`) or a `Decodable` existential (`Se_`),
    /// in Swift's mangling of the callee's signature, such as `JSONDecoder.decode(_:from:)` or
    /// `KeyedDecodingContainer.decode(_:forKey:)`.
    private static func mayDecode(unindexedUsr usr: String) -> Bool {
        usr.range(of: "Se(R[zd]|_)", options: .regularExpression) != nil
    }

    /// `decode(_:from:)` of `JSONDecoder` and `PropertyListDecoder`, and `decode`/`decodeIfPresent` of the keyed,
    /// unkeyed and single-value decoding containers, matched on the exact module and type in the USR: the standard
    /// library (`s:s`) or Foundation (`s:10Foundation`, and `s:20FoundationEssentials` on Linux) followed by the
    /// length-prefixed type name and its kind. A same-named type from another module does not match.
    private static func isStandardDecodingCall(usr: String) -> Bool {
        let types = ["11JSONDecoderC", "19PropertyListDecoderC", "22KeyedDecodingContainerV", "30KeyedDecodingContainerProtocolP",
                     "24UnkeyedDecodingContainerP", "28SingleValueDecodingContainerP"]
        let exact = "^s:(s|10Foundation|20FoundationEssentials)(\(types.joined(separator: "|")))(sE)?(6decode|15decodeIfPresent)"
        return usr.range(of: exact, options: .regularExpression) != nil
    }

    private static let transparentContainers: Set<String> = ["Optional", "Array", "ContiguousArray", "Set", "Dictionary"]

    /// Adds the generic arguments of specialized types that the coding reaches. The standard containers pass every
    /// argument through. Another generic type passes an argument only when one of its coded stored properties, as
    /// `classify` decides for the direction, has a declared type that reaches the matching generic parameter through
    /// standard containers alone: a phantom parameter, or one inside another generic wrapper such as `Phantom<T>`,
    /// is not coded.
    private func withGenericArguments(
        _ references: Set<Reference>,
        classify: (Declaration, Declaration) -> PropertyUse
    ) -> Set<Reference> {
        var result = references
        for reference in references where !reference.genericArguments.isEmpty {
            guard let base = graph.declaration(withUsr: reference.usr) else {
                if Self.transparentContainers.contains(reference.name) {
                    result.formUnion(reference.genericArguments.flatMap(\.self))
                }
                continue
            }

            // A generic typealias such as `Payload<T> = Page<T>` is not mapped to its target's parameters: every argument
            // passes through, which retains more than strictly necessary.
            if base.kind == .typealias {
                result.formUnion(reference.genericArguments.flatMap(\.self))
                continue
            }
            guard base.kind == .struct else { continue }

            let parameters = base.declarations.filter { $0.kind == .genericTypeParam }.sorted()
            let storedTypes = base.declarations
                .filter { $0.kind == .varInstance && classify(base, $0) != .skip }
                .compactMap(\.declaredType)
            for (parameter, arguments) in zip(parameters, reference.genericArguments)
                where storedTypes.contains(where: { type($0, reaches: parameter.name, classify: classify) })
            {
                result.formUnion(arguments)
            }
        }
        return result
    }

    /// Whether a declared type is the generic parameter or reaches it through the standard containers (`Optional`,
    /// `Array`, `ContiguousArray`, `Set` and `Dictionary`, spelled out or as `?`, `!`, `[]` and `[:]`) or through a
    /// generic struct of the scan that itself stores the matching parameter, such as `Box<T>` storing `T`. A wrapper
    /// that does not store its parameter does not reach it. Whether the wrapper is itself decoded synthesized is not
    /// checked, which retains more than strictly necessary.
    private func type(_ declared: String, reaches parameter: String, classify: (Declaration, Declaration) -> PropertyUse, depth: Int = 0) -> Bool {
        var type = declared.filter { !$0.isWhitespace }
        while let last = type.last, last == "?" || last == "!" {
            type.removeLast()
        }
        if type.hasPrefix("Swift.") {
            type.removeFirst("Swift.".count)
        }
        if type == parameter {
            return true
        }
        if type.hasPrefix("["), type.hasSuffix("]") {
            let inner = String(type.dropFirst().dropLast())
            return Self.topLevelParts(of: inner, separator: ":").contains { self.type($0, reaches: parameter, classify: classify, depth: depth) }
        }
        guard let open = type.firstIndex(of: "<"), type.hasSuffix(">") else { return false }

        let name = String(type[..<open])
        let arguments = Self.topLevelParts(of: String(type[type.index(after: open)...].dropLast()), separator: ",")
        if Self.transparentContainers.contains(name) {
            return arguments.contains { self.type($0, reaches: parameter, classify: classify, depth: depth) }
        }

        // A user's generic wrapper reaches the parameter when an argument does and the wrapper stores its own
        // matching parameter.
        guard depth < 4 else { return false }

        let simpleName = name.split(separator: ".").last.map(String.init) ?? name
        for wrapper in graph.declarations(ofKind: .struct) where wrapper.name == simpleName {
            let parameters = wrapper.declarations.filter { $0.kind == .genericTypeParam }.sorted()
            let stored = wrapper.declarations.filter { $0.kind == .varInstance && classify(wrapper, $0) != .skip }.compactMap(\.declaredType)
            for (own, argument) in zip(parameters, arguments)
                where self.type(argument, reaches: parameter, classify: classify, depth: depth + 1)
                && stored.contains(where: { self.type($0, reaches: own.name, classify: classify, depth: depth + 1) })
            {
                return true
            }
        }
        return false
    }

    /// Splits at a separator outside any brackets, `<>`, `[]` or `()`; a type without one is a single part.
    private static func topLevelParts(of text: String, separator: Character) -> [String] {
        var parts: [String] = []
        var depth = 0
        var current = ""
        for character in text {
            switch character {
            case "<", "[", "(": depth += 1
            case ">", "]", ")": depth -= 1
            default: break
            }
            if character == separator, depth == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts
    }

    /// The enum that supplies the keys: the declaration itself, or the target of a typealias. A type whose keys
    /// cannot be resolved is not modeled at all.
    private func codingKeyEnum(for declaration: Declaration) -> Declaration? {
        var keys = declaration
        if declaration.kind == .typealias {
            guard let target = resolveTypealias(declaration)?.declaration, target.kind == .enum else { return nil }

            keys = target
        }
        let isCodingKey = graph.inheritedTypeReferences(of: keys).contains { $0.declarationKind == .protocol && $0.name == "CodingKey" }
        return isCodingKey ? keys : nil
    }

    /// Whether an explicit `CodingKeys` enum, or a typealias of one, leaves the property out of the synthesized
    /// coding. A type whose keys cannot be resolved codes nothing that is modeled.
    private func isOmittedByCodingKeys(_ property: Declaration, in type: Declaration) -> Bool {
        let extensions = graph.extensions[type] ?? []
        let nested = type.declarations.union(extensions.flatMap(\.declarations))
        guard let codingKeys = nested.first(where: { $0.name == "CodingKeys" && !$0.isImplicit && [.enum, .typealias].contains($0.kind) }) else { return false }

        // A typealias whose target is outside the scan cannot be inspected: every property stays eligible.
        if codingKeys.kind == .typealias, resolveTypealias(codingKeys).map({ $0.declaration == nil }) == true { return false }
        guard let keys = codingKeyEnum(for: codingKeys) else { return true }

        return !keys.declarations.contains { $0.kind == .enumelement && $0.name == property.name }
    }

    /// How the synthesized `init(from:)` treats a stored property.
    private func decodeUse(of property: Declaration, in type: Declaration) -> PropertyUse {
        // Computed properties, lazy properties and a `let` with an initial value are never decoded: the
        // synthesized initializer does not assign them.
        guard !property.isImplicit, !property.hasAccessorBody, !property.isInitializedConstant,
              !property.modifiers.contains("lazy") else { return .skip }

        guard !isOmittedByCodingKeys(property, in: type) else { return .skip }

        // `declaredType` is sanitized of `?` and `!`, so read optionality from the property's mangled
        // type: `Int?`, `Int!` and `Optional<Int>` all end in the `Sg` sugar before the `vp` suffix. An optional
        // property is decoded with `decodeIfPresent`, so it is not required, but its type is still decoded.
        if property.usrs.contains(where: { $0.hasSuffix("Sgvp") }) {
            return .traverse
        }

        return .read
    }

    private enum PropertyUse {
        /// Not decoded or encoded at all.
        case skip
        /// Its type is coded, but nothing requires the property itself.
        case traverse
        /// Required by the synthesized initializer or encoder.
        case read
    }

    private func markReads(
        from use: Reference,
        caller: Declaration?,
        synthesizedTypes: Set<Declaration>,
        referencedBy references: Set<Reference>,
        classify: (Declaration, Declaration) -> PropertyUse
    ) {
        var visited: Set<Declaration> = []
        var types = ValueTypeResolver.valueTypes(referencedBy: references, in: graph, visited: &visited)
        var seen: Set<Declaration> = []
        while let type = types.popFirst() {
            guard synthesizedTypes.contains(type), seen.insert(type).inserted else { continue }

            for property in type.declarations where property.kind == .varInstance {
                let propertyUse = classify(type, property)
                guard propertyUse != .skip else { continue }

                // Synthesized coding handles stored values recursively.
                // A generic argument is decoded only when its generic type stores it; a plain type is followed whole.
                let stored = property.references.filter {
                    !$0.isGenericSpecializationArgument && ![.functionAccessorGetter, .functionAccessorSetter].contains($0.declarationKind)
                }
                types.formUnion(ValueTypeResolver.valueTypes(referencedBy: withGenericArguments(stored, classify: classify), in: graph, visited: &visited))
                guard propertyUse == .read else { continue }

                for target in [property] + property.declarations.filter({ $0.kind == .functionAccessorGetter }) {
                    for usr in target.usrs {
                        let reference = Reference(name: target.name, kind: .normal, declarationKind: target.kind, usr: usr, location: use.location)
                        reference.parent = caller
                        if let caller {
                            graph.add(reference, from: caller)
                        } else {
                            graph.addRoot(reference)
                        }
                    }
                }
            }
        }
    }
}
