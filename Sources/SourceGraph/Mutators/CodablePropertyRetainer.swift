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
            guard !members.contains(where: { $0.name == "encode(to:)" && !$0.isImplicit }) else { continue }

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
            !property.isImplicit && !property.isComplexProperty
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
            guard !members.contains(where: { $0.name == "init(from:)" && !$0.isImplicit }) else { continue }

            synthesizedTypes.insert(type)
        }

        guard !synthesizedTypes.isEmpty else { return }

        let decodableNames = decodableProtocolNames

        for use in graph.allReferences where use.kind == .normal && !use.valueArgumentReferences.isEmpty {
            guard let caller = use.parent, !caller.isImplicit else { continue }

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

            markReads(from: use, caller: caller, synthesizedTypes: synthesizedTypes, referencedBy: decoded) { type, property in
                isDecoded(property, of: type)
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
        for argument in use.valueArguments {
            while index < parameters.count, parameters[index].label != argument.label {
                index += 1
            }
            guard index < parameters.count else { return [] }

            if !parameters[index].names.isDisjoint(with: decodableNames) {
                decoded.formUnion(argument.references)
            }
            // A variadic parameter takes the arguments that follow it too.
            if !parameters[index].isVariadic {
                index += 1
            }
        }
        return decoded
    }

    private func mayDecode(indexed callee: Declaration) -> Bool {
        callee.references.contains { reference in
            switch reference.role {
            case .genericParameterType, .genericRequirementType:
                Self.decodableUsrs.contains(reference.usr)
                    || graph.declaration(withUsr: reference.usr).map { graph.isDecodable($0) } == true
            case .parameterType:
                // Only an existential parameter; a concrete Decodable type is not evidence.
                Self.decodableUsrs.contains(reference.usr)
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

    private func isDecoded(_ property: Declaration, of type: Declaration) -> Bool {
        // A `let` with an initial value cannot be assigned, so the synthesized initializer skips it.
        guard !property.isImplicit, !property.isComplexProperty, !property.isInitializedConstant else { return false }

        // `declaredType` is sanitized of `?` and `!`, so read optionality from the property's mangled
        // type: `Int?`, `Int!` and `Optional<Int>` all end in the `Sg` sugar before the `vp` suffix.
        if property.usrs.contains(where: { $0.hasSuffix("Sgvp") }) {
            return false
        }

        // An explicit CodingKeys enum limits the properties the synthesized initializer decodes.
        let extensions = graph.extensions[type] ?? []
        let nested = type.declarations.union(extensions.flatMap(\.declarations))
        let codingKeys = nested.first {
            $0.kind == .enum && $0.name == "CodingKeys" && !$0.isImplicit
                && graph.inheritedTypeReferences(of: $0).contains { $0.declarationKind == .protocol && $0.name == "CodingKey" }
        }
        if let codingKeys {
            return codingKeys.declarations.contains { $0.kind == .enumelement && $0.name == property.name }
        }

        return true
    }

    private func markReads(
        from use: Reference,
        caller: Declaration,
        synthesizedTypes: Set<Declaration>,
        referencedBy references: Set<Reference>,
        includes: (Declaration, Declaration) -> Bool
    ) {
        var visited: Set<Declaration> = []
        var types = ValueTypeResolver.valueTypes(referencedBy: references, in: graph, visited: &visited)
        var seen: Set<Declaration> = []
        while let type = types.popFirst() {
            guard synthesizedTypes.contains(type), seen.insert(type).inserted else { continue }

            let properties = type.declarations.filter { $0.kind == .varInstance && includes(type, $0) }
            for property in properties {
                // Synthesized coding handles stored values recursively.
                types.formUnion(ValueTypeResolver.valueTypes(referencedBy: property.references, in: graph, visited: &visited))
                for target in [property] + property.declarations.filter({ $0.kind == .functionAccessorGetter }) {
                    for usr in target.usrs {
                        let reference = Reference(name: target.name, kind: .normal, declarationKind: target.kind, usr: usr, location: use.location)
                        reference.parent = caller
                        graph.add(reference, from: caller)
                    }
                }
            }
        }
    }
}
