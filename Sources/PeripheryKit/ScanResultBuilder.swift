import Configuration
import Foundation
import SourceGraph

public enum ScanResultBuilder {
    public static func build(for graph: SourceGraph, configuration: Configuration, confidence: ConfidenceAssessor) -> [ScanResult] {
        let assignOnlyProperties = graph.assignOnlyProperties
        let removableDeclarations = graph.unusedDeclarations
            .subtracting(assignOnlyProperties)
            .union(graph.unusedModuleImports)
        let redundantProtocols = graph.redundantProtocols.filter { !removableDeclarations.contains($0.0) }
        let redundantPublicAccessibility = graph.redundantPublicAccessibility.filter { !removableDeclarations.contains($0.0) }

        let annotatedRemovableDeclarations: [ScanResult] = removableDeclarations.flatMap { removableDeclaration in
            var extensionResults = [ScanResult]()

            if removableDeclaration.kind.isExtendableKind,
               !graph.retainedDeclarations.contains(removableDeclaration),
               !graph.ignoredDeclarations.contains(removableDeclaration)
            {
                let decls = removableDeclaration.descendentDeclarations.union([removableDeclaration])

                for decl in decls {
                    let extensions = graph.extensions[decl, default: []]
                    for ext in extensions {
                        extensionResults.append(ScanResult(declaration: ext, annotation: .unused))
                    }
                }
            }

            return [ScanResult(declaration: removableDeclaration, annotation: .unused)] + extensionResults
        }
        let annotatedAssignOnlyProperties: [ScanResult] = assignOnlyProperties.map {
            .init(declaration: $0, annotation: .assignOnlyProperty)
        }
        let annotatedRedundantProtocols: [ScanResult] = redundantProtocols.map { decl, tuple in
            let (references, inherited) = tuple
            let inheritedNames = inherited.compactMapSet { $0.name }
            return .init(declaration: decl, annotation: .redundantProtocol(references: references, inherited: inheritedNames))
        }
        let annotatedRedundantPublicAccessibility: [ScanResult] = redundantPublicAccessibility.map {
            .init(declaration: $0.0, annotation: .redundantPublicAccessibility(modules: $0.1))
        }

        let annotatedUnconstructedEnumCases: [ScanResult] = graph.unconstructedEnumCases
            .filter { !removableDeclarations.contains($0) }
            .map { .init(declaration: $0, annotation: .unconstructedEnumCase) }
        let annotatedSuperfluousIgnoreCommands: [ScanResult] = {
            guard configuration.superfluousIgnoreComments else { return [] }

            // Detect superfluous ignore commands.
            let superfluousDeclarations = graph.commandIgnoredDeclarations
                .filter { _, kind in kind == .declaration }
                .keys
                .filter { decl in
                    hasReferencesFromNonIgnoredCode(decl, graph: graph)
                        && !graph.suppressedAssignOnlyProperties.contains(decl)
                }

            // 2. Parameters with ignore comments that are actually used (not in unusedParameters)
            let superfluousParamResults = findSuperfluousParameterIgnores(graph: graph)

            return superfluousDeclarations
                .map { .init(declaration: $0, annotation: .superfluousIgnoreCommand) }
                + superfluousParamResults
        }()

        let allAnnotatedDeclarations = annotatedRemovableDeclarations +
            annotatedAssignOnlyProperties +
            annotatedRedundantProtocols +
            annotatedRedundantPublicAccessibility +
            annotatedSuperfluousIgnoreCommands +
            annotatedUnconstructedEnumCases

        return allAnnotatedDeclarations
            .filter { result in
                guard !result.declaration.isImplicit,
                      !result.declaration.kind.isAccessorKind,
                      !graph.ignoredDeclarations.contains(result.declaration)
                else { return false }

                // Superfluous ignore command results must bypass the retained filter below.
                // Declarations with ignore comments are always in retainedDeclarations (that's
                // how ignore comments work), so filtering them out would prevent us from ever
                // reporting superfluous ignore commands.
                if case .superfluousIgnoreCommand = result.annotation {
                    return true
                }

                return !graph.retainedDeclarations.contains(result.declaration)
            }
            .map { result in
                let assessment = confidence.assess(result.declaration)
                return ScanResult(
                    declaration: result.declaration,
                    annotation: result.annotation,
                    confidence: assessment.confidence,
                    confidenceReason: assessment.reason,
                    reason: reason(for: result.declaration, annotation: result.annotation, graph: graph)
                )
            }
    }

    /// One sentence a reader can act on without running `lethen explain`.
    static func reason(for declaration: Declaration, annotation: ScanResult.Annotation, graph: SourceGraph) -> String {
        switch annotation {
        case .unused:
            if declaration.kind == .module {
                return "no declaration of the module is used in this file"
            }
            let references = graph.references(to: declaration)
            if let reason = protocolReason(for: declaration, references: references, graph: graph) {
                return reason
            }
            let referencing = Set(references.compactMap(\.parent))
            if referencing.isEmpty {
                return "no references in the scanned modules"
            }
            return "referenced only from \(referencing.count) unused declaration\(referencing.count == 1 ? "" : "s")"
        case .assignOnlyProperty:
            return "assigned but never read"
        case .redundantProtocol:
            return "conformed to but never used as a type"
        case let .redundantPublicAccessibility(modules):
            return "not referenced outside \(modules.sorted().joined(separator: ", "))"
        case .superfluousIgnoreCommand:
            return "referenced from used code"
        case .unconstructedEnumCase:
            return "matched in patterns but never constructed"
        }
    }

    /// The reason of an unused protocol requirement that nothing references but its own witnesses, and of a witness
    /// that only unused requirements reference. The protocol conformance builder points a requirement's `related`
    /// references at its witnesses, and a default implementation's back at the requirement.
    private static func protocolReason(for declaration: Declaration, references: Set<Reference>, graph: SourceGraph) -> String? {
        let (participle, verb) = declaration.kind.isFunctionKind ? ("called", "calls") : ("used", "uses")
        if let proto = declaration.parent, proto.kind == .protocol {
            guard references.allSatisfy({ $0.kind == .related }) else { return nil }

            let witnesses = declaration.related
                .compactMapSet { graph.declaration(withUsr: $0.usr) }
                .filter { $0.parent?.kind != .protocol }
            let reason = "never \(participle) through \(proto.name)"
            guard !witnesses.isEmpty else { return reason }

            let direct = witnesses.count { graph.usedDeclarations.contains($0) }
            return "\(reason); \(direct) of \(witnesses.count) witness\(witnesses.count == 1 ? "" : "es") \(direct == 1 ? "is" : "are") \(participle) directly"
        }

        let requirements = references.compactMapSet(\.parent)
        guard let requirement = requirements.first, requirements.count == 1,
              let proto = requirement.parent, proto.kind == .protocol,
              references.allSatisfy({ $0.kind == .related }),
              !graph.usedDeclarations.contains(requirement)
        else { return nil }

        return "witness of \(proto.name).\(requirement.name), which nothing \(verb) through the protocol; remove it with the requirement"
    }

    /// Checks if a declaration has references from code that is not part of the command ignored set.
    /// This indicates that the declaration would have been marked as used even without the ignore command.
    private static func hasReferencesFromNonIgnoredCode(_ decl: Declaration, graph: SourceGraph) -> Bool {
        let references = graph.references(to: decl)
        let isProtocolMember = decl.parent?.kind == .protocol

        for ref in references {
            guard ref.kind != .retained, let parent = ref.parent else { continue }

            // Protocol members naturally accumulate related references from conformances and
            // default implementations even when genuinely unused. Only normal references indicate
            // actual usage.
            if isProtocolMember, ref.kind != .normal { continue }

            if graph.commandIgnoredDeclarations[parent] == nil {
                if graph.usedDeclarations.contains(parent) {
                    return true
                }
            }
        }

        return false
    }

    /// Finds parameters that have `// periphery:ignore:parameters` comments but are actually used.
    /// If a parameter is ignored but NOT in unusedParameters, it means it's used and the ignore is superfluous.
    private static func findSuperfluousParameterIgnores(graph: SourceGraph) -> [ScanResult] {
        var results: [ScanResult] = []

        for decl in graph.functionsWithIgnoredParameters {
            let ignoredParamNames = decl.commentCommands.ignoredParameterNames
            let unusedParamNames = Set(decl.unusedParameters.compactMap(\.name))

            for ignoredParamName in ignoredParamNames {
                if !unusedParamNames.contains(ignoredParamName) {
                    // The ignored parameter is actually used - create a result for it
                    let parentUsrs = decl.usrs.sorted().joined(separator: "-")
                    let usr = "param-\(ignoredParamName)-\(decl.name)-\(parentUsrs)"
                    let paramDecl = Declaration(
                        name: ignoredParamName,
                        kind: .varParameter,
                        usrs: [usr],
                        location: decl.location
                    )
                    paramDecl.parent = decl
                    results.append(.init(declaration: paramDecl, annotation: .superfluousIgnoreCommand))
                }
            }
        }

        return results
    }
}
