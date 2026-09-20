import Configuration
import Foundation
import Shared

final class PropertyWrapperRetainer: SourceGraphMutator {
    private let graph: SourceGraph
    private let specialProperties = ["wrappedValue", "projectedValue"]

    required init(graph: SourceGraph, configuration _: Configuration, swiftVersion _: SwiftVersion) {
        self.graph = graph
    }

    func mutate() {
        buildProjectedValueReferences()

        for decl in graph.declarations(ofKinds: Declaration.Kind.toplevelAttributableKind) where decl.attributes.contains(where: { $0.name == "propertyWrapper" }) {
            decl.declarations
                .filter { $0.kind == .varInstance && specialProperties.contains($0.name) }
                .forEach { graph.markRetained($0) }
        }
    }

    /// Attached macros can emit a projected property whose getter only references generated
    /// storage. Preserve the connection from actual projection uses to the source property.
    private func buildProjectedValueReferences() {
        for property in graph.declarations(ofKind: .varInstance) {
            guard !property.isImplicit, !property.attributes.isEmpty,
                  let parent = property.parent else { continue }

            let projections = parent.declarations.filter {
                $0.isImplicit && $0.kind == .varInstance && $0.name == "$" + property.name
            }
            for projection in projections {
                for use in graph.references(to: projection) {
                    // Generated declarations are retained independently. Connecting them would
                    // also retain an unused projection, so preserve only source-level callers.
                    guard use.kind == .normal, let caller = use.parent, !caller.isImplicit else { continue }

                    for usr in property.usrs {
                        let reference = Reference(
                            name: property.name,
                            kind: .normal,
                            declarationKind: property.kind,
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
