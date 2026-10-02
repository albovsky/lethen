import Configuration
import Foundation
import Shared

final class CodablePropertyRetainer: SourceGraphMutator {
    private static let encodableUsrs: Set<String> = ["s:SE", "s:s7Codablea"]
    private static let decodableUsrs: Set<String> = ["s:Se", "s:s7Codablea"]

    private let graph: SourceGraph
    private let configuration: Configuration

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
        for type in graph.declarations(ofKind: .struct) {
            guard graph.isEncodable(type) else { continue }

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
        markReads(from: use, caller: caller, synthesizedTypes: synthesizedTypes, referencedBy: use.valueArgumentReferences) { _, property in
            !property.isImplicit && !property.isComplexProperty ? .read : .skip
        }
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

            markReads(from: use, caller: caller, synthesizedTypes: synthesizedTypes, referencedBy: withDecodedGenericArguments(decoded)) { type, property in
                decodeUse(of: property, in: type)
            }
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
        return type == parameterType
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
    /// unkeyed and single-value decoding containers, in the standard library's and Foundation's mangling.
    private static func isStandardDecodingCall(usr: String) -> Bool {
        let isDecoder = usr.contains("JSONDecoderC") || usr.contains("PropertyListDecoderC")
        let isContainer = usr.contains("DecodingContainer")
        return (isDecoder || isContainer) && usr.range(of: "(6decode|15decodeIfPresent)_", options: .regularExpression) != nil
    }

    /// A specialized metatype such as `Page<Model>.self` decodes `Model` only when `Page` stores a value of that
    /// generic parameter in a decoded property; a phantom parameter is never decoded. The parameter is matched by
    /// name against the declared types of the base type's decoded properties, and only when a type is the parameter or a
    /// standard container of it. A parameter inside another generic wrapper such as `Phantom<T>` is not followed.
    private func withDecodedGenericArguments(_ references: Set<Reference>) -> Set<Reference> {
        var result = references
        for reference in references where !reference.genericArguments.isEmpty {
            guard let base = graph.declaration(withUsr: reference.usr), base.kind == .struct else { continue }

            let parameters = base.declarations.filter { $0.kind == .genericTypeParam }.sorted()
            let storedTypes = base.declarations
                .filter { $0.kind == .varInstance && decodeUse(of: $0, in: base) != .skip }
                .compactMap(\.declaredType)
            for (parameter, arguments) in zip(parameters, reference.genericArguments) {
                let name = NSRegularExpression.escapedPattern(for: parameter.name)
                let other = "[A-Za-z_][A-Za-z0-9_.]*"
                let shapes = [name, "\\[\(name)\\]", "\\[\(name):\(other)\\]", "\\[\(other):\(name)\\]"]
                    + ["Set<\(name)>", "Array<\(name)>", "Optional<\(name)>", "Dictionary<\(name),\(other)>", "Dictionary<\(other),\(name)>"]
                let pattern = "^(Swift\\.)?(\(shapes.joined(separator: "|")))$"
                let mentioned = storedTypes.contains {
                    $0.filter { !$0.isWhitespace }.range(of: pattern, options: .regularExpression) != nil
                }
                if mentioned {
                    result.formUnion(arguments)
                }
            }
        }
        return result
    }

    /// How the synthesized `init(from:)` treats a stored property.
    private func decodeUse(of property: Declaration, in type: Declaration) -> PropertyUse {
        // Computed properties, lazy properties and a `let` with an initial value are never decoded: the
        // synthesized initializer does not assign them.
        guard !property.isImplicit, !property.isComplexProperty, !property.isInitializedConstant,
              !property.modifiers.contains("lazy") else { return .skip }

        // An explicit CodingKeys enum limits the properties the synthesized initializer decodes.
        let extensions = graph.extensions[type] ?? []
        let nested = type.declarations.union(extensions.flatMap(\.declarations))
        let codingKeys = nested.first {
            $0.kind == .enum && $0.name == "CodingKeys" && !$0.isImplicit
                && graph.inheritedTypeReferences(of: $0).contains { $0.declarationKind == .protocol && $0.name == "CodingKey" }
        }
        if let codingKeys, !codingKeys.declarations.contains(where: { $0.kind == .enumelement && $0.name == property.name }) {
            return .skip
        }

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
                types.formUnion(ValueTypeResolver.valueTypes(referencedBy: property.references, in: graph, visited: &visited))
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
