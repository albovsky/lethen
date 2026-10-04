import Configuration
import SourceGraph
import SyntaxAnalysis

/// Adds the unused parameters of the file's functions to their declarations and to the graph. A parameter is
/// retained when the whole file is retained, when its function is reachable from Objective-C and
/// `retainObjcAccessible` is set, or when the function's `periphery:ignore(parameters:)` command names it.
struct UnusedParameterAnalysis: SyntaxAnalysis {
    private let retainObjcAccessible: Bool

    init(configuration: Configuration) {
        retainObjcAccessible = configuration.retainObjcAccessible
    }

    func apply(to file: IndexedFile) throws {
        // Variables too: a closure stored in a property is analyzed like a function.
        let functionDecls = file.declarations.filter { $0.kind.isFunctionKind || $0.kind.isVariableKind }
        let functionDeclsByLocation = functionDecls.reduce(into: [Location: Declaration]()) {
            $0[$1.location] = $1
        }

        // Build a map of ignored param names per function, and track functions with ignored
        // params so ScanResultBuilder can efficiently detect superfluous ignores.
        var ignoredParamsByLocation: [Location: [String]] = [:]
        for functionDecl in functionDecls {
            let ignoredParamNames = functionDecl.commentCommands.ignoredParameterNames
            if !ignoredParamNames.isEmpty {
                ignoredParamsByLocation[functionDecl.location] = ignoredParamNames
                file.graph.withLock { $0.markHasIgnoredParameters(functionDecl) }
            }
        }

        let paramsByFunction = UnusedParameterAnalyzer().analyze(
            file: file.sourceFile,
            syntax: file.syntax,
            locationConverter: file.locationConverter,
            parseProtocols: true
        )

        for (function, params) in paramsByFunction {
            guard let functionDecl = functionDeclsByLocation[function.location] else {
                // The declaration may not exist if the code was not compiled due to build conditions, e.g #if.
                file.logger.debug("Failed to associate indexed function for parameter function '\(function.name)' at \(function.location).")
                continue
            }

            let ignoredParamNames = ignoredParamsByLocation[functionDecl.location] ?? []

            file.graph.withLock { graph in
                for param in params {
                    let paramDecl = param.makeDeclaration(withParent: functionDecl)
                    functionDecl.unusedParameters.insert(paramDecl)
                    graph.add(paramDecl)

                    if file.retainsAllDeclarations || (functionDecl.isObjcAccessible && retainObjcAccessible) {
                        graph.markRetained(paramDecl)
                    } else if ignoredParamNames.contains(param.name.text) {
                        graph.markRetained(paramDecl)
                        graph.markCommandIgnored(paramDecl, kind: .declaration)
                    }
                }
            }
        }
    }
}
