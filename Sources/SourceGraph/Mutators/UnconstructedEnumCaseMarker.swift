import Configuration
import Foundation
import Shared

/// Marks enum cases that only ever appear in patterns. A case that is matched but never constructed
/// is dead together with the arms that match it.
final class UnconstructedEnumCaseMarker: SourceGraphMutator {
    private static let constructingProtocols: Set<String> = ["CaseIterable", "Decodable", "Codable"]

    private let graph: SourceGraph

    required init(graph: SourceGraph, configuration _: Configuration, swiftVersion _: SwiftVersion) {
        self.graph = graph
    }

    func mutate() {
        for enumDecl in graph.declarations(ofKind: .enum) where canConstructOnlyExplicitly(enumDecl) {
            for enumCase in enumDecl.declarations where enumCase.kind == .enumelement && !enumCase.isImplicit {
                let references = graph.references(to: enumCase).filter { $0.kind != .retained }
                guard !references.isEmpty, references.allSatisfy({ $0.role == .enumCasePattern }) else { continue }

                graph.markUnconstructedEnumCase(enumCase)
            }
        }
    }

    /// Enums whose cases are constructed only by name: not retained (a public enum under
    /// --retain-public can be constructed by clients), not ignored, and with no initializer that
    /// produces cases dynamically.
    private func canConstructOnlyExplicitly(_ enumDecl: Declaration) -> Bool {
        guard !graph.isRetained(enumDecl), graph.commandIgnoredDeclarations[enumDecl] == nil,
              !graph.isRawRepresentable(enumDecl), !graph.isCodable(enumDecl),
              !enumDecl.attributes.contains(where: { $0.name == "objc" }) else { return false }

        return !graph.inheritedTypeReferences(of: enumDecl).contains {
            [.protocol, .typealias].contains($0.declarationKind) && Self.constructingProtocols.contains($0.name)
        }
    }
}
