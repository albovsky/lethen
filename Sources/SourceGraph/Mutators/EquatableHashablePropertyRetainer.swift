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

    /// Model omitted synthesized bodies only when a whole value reaches a call.
    /// Indexed generic Equatable APIs and unindexed APIs may compare their arguments;
    /// constructing a local value or reading one of its fields is not such evidence.
    private func buildSynthesizedEqualityReads() {
        // Explicit witnesses can live on Equatable itself with a constrained Self.
        // Their related references identify the concrete conformance locations.
        let customWitnessLocations = Set(graph.declarations(ofKind: .functionOperatorInfix)
            .filter { $0.name == "==(_:_:)" && !$0.isImplicit }
            .flatMap { $0.related.filter { $0.usr == "s:SQ2eeoiySbx_xtFZ" }.map(\.location) })
        var synthesizedTypes: Set<Declaration> = []
        for type in graph.declarations(ofKind: .struct) {
            guard graph.isEquatable(type), !customWitnessLocations.contains(type.location),
                  !(graph.extensions[type] ?? []).contains(where: { customWitnessLocations.contains($0.location) }) else { continue }

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

            synthesizedTypes.insert(type)
        }

        for use in graph.allReferences where use.kind == .normal && !use.valueArgumentReferences.isEmpty {
            guard let caller = use.parent, !caller.isImplicit else { continue }

            if let callee = graph.declaration(withUsr: use.usr) {
                let hasEqualityConstraint = callee.references.contains { reference in
                    guard reference.role == .genericParameterType || reference.role == .genericRequirementType else { return false }

                    return reference.usr == "s:SQ" || graph.declaration(withUsr: reference.usr).map { graph.isEquatable($0) } == true
                }
                var visitedCalls: Set<Declaration> = []
                guard hasEqualityConstraint, mayCompareArguments(in: callee, visited: &visitedCalls) else { continue }
            }

            var visited: Set<Declaration> = []
            var types = valueTypes(referencedBy: use.valueArgumentReferences, visited: &visited)
            var compared: Set<Declaration> = []
            while let type = types.popFirst() {
                guard synthesizedTypes.contains(type), compared.insert(type).inserted else { continue }

                let properties = type.declarations.filter {
                    $0.kind == .varInstance && !$0.isImplicit && !$0.isComplexProperty
                }
                for property in properties {
                    // Synthesized equality compares stored values recursively.
                    types.formUnion(valueTypes(referencedBy: property.references, visited: &visited))
                    for target in [property] + property.declarations.filter({ $0.kind == .functionAccessorGetter }) {
                        for usr in target.usrs {
                            let reference = Reference(name: target.name, kind: .normal,
                                                      declarationKind: target.kind, usr: usr, location: use.location)
                            reference.parent = caller
                            graph.add(reference, from: caller)
                        }
                    }
                }
            }
        }
    }

    private func mayCompareArguments(in function: Declaration, visited: inout Set<Declaration>) -> Bool {
        guard visited.insert(function).inserted else { return false }

        for reference in function.references where reference.kind == .normal {
            guard reference.hasGenericValueArguments else { continue }
            guard let called = graph.declaration(withUsr: reference.usr) else { return true }

            if mayCompareArguments(in: called, visited: &visited) {
                return true
            }
        }
        return false
    }

    private func valueTypes(referencedBy references: Set<Reference>, visited: inout Set<Declaration>) -> Set<Declaration> {
        var types: Set<Declaration> = []
        for reference in references {
            guard let declaration = graph.declaration(withUsr: reference.usr), visited.insert(declaration).inserted else { continue }

            if declaration.kind == .struct {
                types.insert(declaration)
            } else if declaration.kind == .functionConstructor, let parent = declaration.parent {
                types.insert(parent)
            } else if declaration.kind == .functionAccessorGetter, let property = declaration.parent {
                types.formUnion(valueTypes(referencedBy: property.references, visited: &visited))
            } else {
                let valueReferences = declaration.references.filter {
                    [.varType, .initializerType, .variableInitFunctionCall, .returnType].contains($0.role)
                }
                types.formUnion(valueTypes(referencedBy: valueReferences, visited: &visited))
            }
        }
        return types
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
