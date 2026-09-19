import Configuration
import Foundation
import Shared

final class EquatableHashablePropertyRetainer: SourceGraphMutator {
    private let graph: SourceGraph
    private let configuration: Configuration

    required init(graph: SourceGraph, configuration: Configuration, swiftVersion _: SwiftVersion) {
        self.graph = graph
        self.configuration = configuration
    }

    func mutate() {
        buildSynthesizedEqualityReads()

        for decl in graph.declarations(ofKinds: Declaration.Kind.discreteConformableKinds) {
            guard decl.kind != .class, shouldRetainProperties(of: decl) else { continue }

            for decl in decl.declarations {
                guard decl.kind == .varInstance else { continue }

                graph.markRetained(decl)
            }
        }
    }

    /// The index omits synthesized equality bodies. A source-level use of a value with
    /// synthesized equality can compare it through generic/external APIs, so model reads
    /// of its stored properties from those callers without making the type a new root.
    private func buildSynthesizedEqualityReads() {
        for type in graph.declarations(ofKind: .struct) {
            guard graph.isEquatable(type) else { continue }

            let members = type.declarations.union(graph.inheritedDeclarations(of: type).flatMap { inherited in
                let extensions = inherited.references
                    .filter { $0.declarationKind == .extensionProtocol }
                    .compactMap { graph.declaration(withUsr: $0.usr) }
                return inherited.declarations.union(extensions.flatMap(\.declarations))
            })
            guard !members.contains(where: { $0.name == "==(_:_:)" && !$0.isImplicit }) else { continue }

            let hasGlobalEquality = graph.references(to: type).contains { use in
                guard use.role == .parameterType, let function = use.parent,
                      function.kind == .functionOperatorInfix, function.name == "==(_:_:)" else { return false }

                return function.related.contains { $0.usr == "s:SQ2eeoiySbx_xtFZ" }
            }
            guard !hasGlobalEquality else { continue }

            let properties = type.declarations.filter {
                $0.kind == .varInstance && !$0.isImplicit && !$0.isComplexProperty
            }
            for use in graph.references(to: type) {
                guard use.kind == .normal, let caller = use.parent, !caller.isImplicit,
                      caller != type, !caller.ancestralDeclarations.contains(type) else { continue }

                for property in properties {
                    for target in [property] + property.declarations.filter({ $0.kind == .functionAccessorGetter }) {
                        for usr in target.usrs {
                            let reference = Reference(
                                name: target.name,
                                kind: .normal,
                                declarationKind: target.kind,
                                usr: usr,
                                location: use.location
                            )
                            reference.parent = caller
                            graph.add(reference, from: caller)
                        }
                    }
                }
            }
        }
    }

    private func shouldRetainProperties(of decl: Declaration) -> Bool {
        if configuration.retainEquatableProperties, graph.isEquatable(decl) {
            return true
        }

        if configuration.retainHashableProperties, graph.isHashable(decl) {
            return true
        }

        return false
    }
}
