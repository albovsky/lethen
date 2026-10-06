import Configuration
import Foundation
import Shared

/// Retains types conforming to App Intents protocols.
///
/// Types conforming to these protocols are discovered and invoked by the system at runtime,
/// so they should not be reported as unused.
final class AppIntentsRetainer: SourceGraphMutator {
    private let graph: SourceGraph

    /// USR prefix for Swift symbols from the AppIntents module.
    /// Swift USRs encode the module name with a length prefix: "s:<length><module_name>..."
    /// For AppIntents (10 characters), this becomes "s:10AppIntents".
    private static let appIntentsModuleUsrPrefix = "s:10AppIntents"

    /// Static requirements of App Intents protocols that the framework reads at runtime.
    ///
    /// A conforming witness such as `static let description = IntentDescription(...)` can differ in
    /// type from the protocol requirement (`IntentDescription?`), in which case the index records no
    /// override relation and the member would otherwise be reported as unused. Only these names are
    /// retained; other static members of an intent are analysed normally.
    private static let staticRequirementNames: Set<String> = [
        "title",
        "description",
        "openAppWhenRun",
        "isDiscoverable",
        "parameterSummary",
        "authenticationPolicy",
        "typeDisplayRepresentation",
        "caseDisplayRepresentations",
        "defaultQuery",
        "appShortcuts",
        "shortcutTileColor",
    ]

    private static let staticMemberKinds: Set<Declaration.Kind> = [
        .varStatic,
        .varClass,
        .functionMethodStatic,
    ]

    required init(graph: SourceGraph, configuration _: Configuration, swiftVersion _: SwiftVersion) {
        self.graph = graph
    }

    func mutate() {
        let appIntentsTypes = graph
            .declarations(ofKinds: [.class, .struct, .enum])
            .filter {
                $0.related.contains {
                    self.graph.isExternal($0) &&
                        $0.declarationKind == .protocol &&
                        $0.usr.hasPrefix(Self.appIntentsModuleUsrPrefix)
                }
            }

        for type in appIntentsTypes {
            graph.markRetained(type)

            for member in type.declarations
                where Self.staticMemberKinds.contains(member.kind) &&
                Self.staticRequirementNames.contains(member.name) &&
                member.related.isEmpty
            {
                graph.markRetained(member)
            }
        }
    }
}
