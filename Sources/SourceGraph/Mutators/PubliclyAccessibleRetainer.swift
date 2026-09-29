import Configuration
import Foundation
import Shared

final class PubliclyAccessibleRetainer: SourceGraphMutator {
    private let graph: SourceGraph
    private let configuration: Configuration

    required init(graph: SourceGraph, configuration: Configuration, swiftVersion _: SwiftVersion) {
        self.graph = graph
        self.configuration = configuration
    }

    func mutate() {
        guard configuration.retainPublic || !configuration.retainPublicTargets.isEmpty else { return }

        let declarationsToRetain = Declaration.Kind.accessibleKinds
            .flatMap { graph.declarations(ofKind: $0) }
            .filter { graph.isRetainedPublicAPI($0) }

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
