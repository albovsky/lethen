import Configuration
import Foundation
import Shared

final class UnusedParameterRetainer: SourceGraphMutator {
    private let graph: SourceGraph
    private let configuration: Configuration

    required init(graph: SourceGraph, configuration: Configuration, swiftVersion _: SwiftVersion) {
        self.graph = graph
        self.configuration = configuration
    }

    func mutate() throws {
        let functionDecls = graph
            .declarations(ofKind: .varParameter) // These are only unused params.
            .compactMapSet { $0.parent }

        retainParams(inFunctions: functionDecls)

        for protoDecl in graph.declarations(ofKind: .protocol) {
            let protoFuncDecls = protoDecl.declarations.filter { functionDecls.contains($0) }

            for protoFuncDecl in protoFuncDecls {
                let relatedFuncDecls = protoFuncDecl.related
                    .filter(\.declarationKind.isFunctionKind)
                    .compactMapSet { graph.declaration(withUsr: $0.usr) }
                let extFuncDecls = relatedFuncDecls.filter { $0.parent?.kind.isExtensionKind ?? false }
                let conformingDecls = relatedFuncDecls.subtracting(extFuncDecls)

                if graph.isRetainedPublicAPI(protoDecl) {
                    // The requirement is retained public API, so clients outside the scan may call it through any
                    // conformance, and its signature cannot change without breaking them.
                    let overrideDecls = conformingDecls.flatMap { graph.allOverrideDeclarations(fromBase: $0) }
                    retainPublicAPIParams(inFunctions: conformingDecls + overrideDecls + extFuncDecls + [protoFuncDecl])
                } else if conformingDecls.isEmpty {
                    // This protocol function declaration is not implemented, though it may still be referenced from an
                    // existential type. Leaving the function parameters as unused would put produce awkward results.
                    let allFunctionDecls = extFuncDecls + [protoFuncDecl]
                    for functionDecl in allFunctionDecls {
                        functionDecl.unusedParameters.forEach { graph.markRetained($0) }
                    }
                } else {
                    let overrideDecls = conformingDecls.flatMap { graph.allOverrideDeclarations(fromBase: $0) }
                    let allFunctionDecls = conformingDecls + overrideDecls + extFuncDecls + [protoFuncDecl]

                    if allFunctionDecls.contains(where: isReferencedAsValue) {
                        retainFunctionValueParams(inFunctions: allFunctionDecls)
                        continue
                    }

                    for functionDecl in allFunctionDecls {
                        if configuration.retainUnusedProtocolFuncParams {
                            functionDecl.unusedParameters.forEach { graph.markRetained($0) }
                        } else {
                            retain(params: Array(functionDecl.unusedParameters), usedIn: allFunctionDecls)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Private

    private func retainParams(inFunctions functionDecls: Set<Declaration>) {
        var visitedDecls: Set<Declaration> = []

        for functionDecl in functionDecls {
            guard !visitedDecls.contains(functionDecl) else { continue }

            let (baseFunctionDecl, didResolveBase) = graph.baseDeclaration(fromOverride: functionDecl)
            let overrideFunctionDecls = graph.allOverrideDeclarations(fromBase: baseFunctionDecl)
            let allFunctionDecls = overrideFunctionDecls + [baseFunctionDecl]
            visitedDecls.formUnion(allFunctionDecls)

            if allFunctionDecls.contains(where: isRetainedPublicFunction) {
                // Overrides share one signature, so a retained public function anywhere in the chain fixes it.
                retainPublicAPIParams(inFunctions: allFunctionDecls)
            } else if allFunctionDecls.contains(where: isReferencedAsValue) {
                // Likewise, a function type the chain converts to fixes the signature of every function in it.
                retainFunctionValueParams(inFunctions: allFunctionDecls)
            } else if didResolveBase {
                if hasExternalRelatedReferences(from: baseFunctionDecl) {
                    retainAllUnusedParams(inMethods: allFunctionDecls)
                } else {
                    let params = allFunctionDecls.flatMap(\.unusedParameters)
                    retain(params: params, usedIn: allFunctionDecls)
                }
            } else {
                retainAllUnusedParams(inMethods: allFunctionDecls)
            }
        }
    }

    private func hasExternalRelatedReferences(from decl: Declaration) -> Bool {
        decl.relatedEquivalentReferences.contains { graph.isExternal($0) }
    }

    /// Functions only: parameters of closures stored in public properties keep the rules for internal code.
    private func isRetainedPublicFunction(_ decl: Declaration) -> Bool {
        decl.kind.isFunctionKind && graph.isRetainedPublicAPI(decl)
    }

    private func retainPublicAPIParams(inFunctions functionDecls: [Declaration]) {
        retainFixedSignatureParams(inFunctions: functionDecls, as: "a parameter of retained public API")
    }

    private func retainFunctionValueParams(inFunctions functionDecls: [Declaration]) {
        retainFixedSignatureParams(inFunctions: functionDecls, as: "a parameter of a function referenced as a value")
    }

    private func retainFixedSignatureParams(inFunctions functionDecls: [Declaration], as reason: String) {
        let params = Set(functionDecls.flatMap(\.unusedParameters).filter { !graph.isRetained($0) })
        params.forEach { graph.markRetained($0) }

        if graph.recordsRetentionSources {
            graph.recordRetentionSource("\(Self.self), as \(reason)", for: params)
        }
    }

    /// A function referenced without a call, such as one passed or assigned as a value, keeps the signature of the
    /// function type it converts to.
    private func isReferencedAsValue(_ decl: Declaration) -> Bool {
        graph.references(to: decl).contains { $0.kind == .normal && !$0.isCall }
    }

    private func retainAllUnusedParams(inMethods methodDeclarations: [Declaration]) {
        methodDeclarations
            .lazy
            .flatMap(\.unusedParameters)
            .forEach { graph.markRetained($0) }
    }

    private func retain(params: [Declaration], usedIn functionDecls: [Declaration]) {
        for param in params where isParam(param, usedInAnyOf: functionDecls) {
            graph.markRetained(param)
        }
    }

    private func isParam(_ param: Declaration, usedInAnyOf decls: [Declaration]) -> Bool {
        for decl in decls {
            let matchingParam = decl.unusedParameters.first { $0.name == param.name }

            if matchingParam == nil {
                // Used
                return true
            }

            if let param = matchingParam, graph.isRetained(param) {
                // Already retained by a prior analysis, e.g by an ignore command.
                return true
            }
        }

        return false
    }
}
