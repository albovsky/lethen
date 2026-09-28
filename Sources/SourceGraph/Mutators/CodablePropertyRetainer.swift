import Configuration
import Foundation
import Shared

final class CodablePropertyRetainer: SourceGraphMutator {
    private static let encodableUsrs: Set<String> = ["s:SE", "s:s7Codablea"]

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
    /// value reaches a call that may encode it: an unindexed function, or an indexed one that is
    /// generic over `Encodable` or takes an `Encodable` existential.
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

            if let callee = graph.declaration(withUsr: use.usr) {
                let mayEncode = callee.references.contains { reference in
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
                guard mayEncode else { continue }
            }

            var visited: Set<Declaration> = []
            var types = ValueTypeResolver.valueTypes(referencedBy: use.valueArgumentReferences, in: graph, visited: &visited)
            var encoded: Set<Declaration> = []
            while let type = types.popFirst() {
                guard synthesizedTypes.contains(type), encoded.insert(type).inserted else { continue }

                let properties = type.declarations.filter { $0.kind == .varInstance && !$0.isImplicit && !$0.isComplexProperty }
                for property in properties {
                    // Synthesized encoding encodes stored values recursively.
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
}
