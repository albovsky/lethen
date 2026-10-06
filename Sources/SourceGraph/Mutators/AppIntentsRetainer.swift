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

    /// Static requirements of App Intents protocols that the framework reads at runtime, by protocol family.
    ///
    /// A conforming witness such as `static let description = IntentDescription(...)` can differ in
    /// type from the protocol requirement (`IntentDescription?`), in which case the index records no
    /// override relation and the member would otherwise be reported as unused. Only a name declared
    /// by a protocol the type conforms to is retained; other static members, including a name that
    /// only a different App Intents protocol declares, are analysed normally.
    ///
    /// Refinements are matched by name suffix because the index records only the directly conformed
    /// protocol: `AppIntent` and its refinements (`WidgetConfigurationIntent`, `SnapshotIntent`, ...)
    /// end in `Intent`, `AppEntity` and its refinements (`TransientAppEntity`, ...) end in `Entity`.
    private static let intentStaticRequirementNames: Set<String> = [
        "title",
        "description",
        "openAppWhenRun",
        "isDiscoverable",
        "parameterSummary",
        "authenticationPolicy",
        "supportedModes",
        "allowedExecutionTargets",
    ]

    private static let entityStaticRequirementNames: Set<String> = ["typeDisplayRepresentation", "defaultQuery"]
    private static let enumStaticRequirementNames: Set<String> = ["typeDisplayRepresentation", "caseDisplayRepresentations"]
    private static let shortcutsProviderStaticRequirementNames: Set<String> = ["appShortcuts", "shortcutTileColor"]

    private static func staticRequirementNames(forProtocol name: String) -> Set<String> {
        if name.hasSuffix("Intent") {
            return intentStaticRequirementNames
        }

        if name.hasSuffix("Entity") {
            return entityStaticRequirementNames
        }

        if name.hasSuffix("Enum") || name.hasSuffix("UnionValue") {
            return enumStaticRequirementNames
        }

        switch name {
        case "AppValue": return ["typeDisplayRepresentation"]
        case "AppShortcutsProvider": return shortcutsProviderStaticRequirementNames
        default: return []
        }
    }

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

            let requirementNames = type.related
                .filter { $0.declarationKind == .protocol && $0.usr.hasPrefix(Self.appIntentsModuleUsrPrefix) }
                .compactMap { graph.declaration(withUsr: $0.usr)?.name ?? $0.name }
                .reduce(into: Set<String>()) { $0.formUnion(Self.staticRequirementNames(forProtocol: $1)) }

            for member in type.declarations
                where Self.staticMemberKinds.contains(member.kind) &&
                requirementNames.contains(member.name) &&
                member.related.isEmpty
            {
                graph.markRetained(member)
            }
        }
    }
}
