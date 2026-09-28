import Configuration
import Foundation
import Shared

/// Retains static methods used by the Result Builder language feature. The compiler calls them
/// by base name with whatever labels and arity the builder declares, so every overload counts.
final class ResultBuilderRetainer: SourceGraphMutator {
    private static let resultBuilderMethodNames: Set<String> = [
        "buildBlock", "buildExpression", "buildOptional", "buildEither", "buildArray",
        "buildFinalResult", "buildLimitedAvailability", "buildPartialBlock",
    ]

    private let graph: SourceGraph

    required init(graph: SourceGraph, configuration _: Configuration, swiftVersion _: SwiftVersion) {
        self.graph = graph
    }

    func mutate() {
        for decl in graph.declarations(ofKinds: Declaration.Kind.toplevelAttributableKind) where decl.attributes.contains(where: { $0.name == "resultBuilder" }) {
            for childDecl in decl.declarations where childDecl.kind == .functionMethodStatic {
                if let baseName = childDecl.name.split(separator: "(", maxSplits: 1).first, Self.resultBuilderMethodNames.contains(String(baseName)) {
                    graph.markRetained(childDecl)
                }
            }
        }
    }
}
