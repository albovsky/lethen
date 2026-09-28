import Configuration
import Foundation
import Shared

final class PubliclyAccessibleRetainer: SourceGraphMutator {
    private let graph: SourceGraph
    private let configuration: Configuration
    private let noRetainSPIAttributes: [DeclarationAttribute]

    required init(graph: SourceGraph, configuration: Configuration, swiftVersion _: SwiftVersion) {
        self.graph = graph
        self.configuration = configuration
        noRetainSPIAttributes = configuration.noRetainSPI.map { DeclarationAttribute(name: "_spi", arguments: $0) }
    }

    func mutate() {
        let retainedTargets = Set(configuration.retainPublicTargets)
        guard configuration.retainPublic || !retainedTargets.isEmpty else { return }

        let declarations = Declaration.Kind.accessibleKinds.flatMap {
            graph.declarations(ofKind: $0)
        }

        let publicDeclarations = declarations.filter { decl in
            (decl.accessibility.value == .public || decl.accessibility.value == .open)
                && (configuration.retainPublic || !decl.location.file.modules.isDisjoint(with: retainedTargets))
        }

        // Only filter if noRetainSPI is configured (performance optimization)
        let declarationsToRetain: [Declaration] = if configuration.noRetainSPI.isEmpty {
            publicDeclarations
        } else {
            publicDeclarations.filter { decl in
                decl.attributes.isDisjoint(with: noRetainSPIAttributes)
            }
        }

        declarationsToRetain.forEach { graph.markRetained($0) }

        // Enum cases inherit the accessibility of the enum.
        declarationsToRetain
            .lazy
            .filter { $0.kind == .enum }
            .flatMap(\.declarations)
            .filter { $0.kind == .enumelement }
            .forEach { graph.markRetained($0) }
    }
}
