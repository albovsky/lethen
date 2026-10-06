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

        // Build a map of ignored param names per function. Functions with ignored params are tracked below, so
        // ScanResultBuilder can efficiently detect superfluous ignores.
        var ignoredParamsByLocation: [Location: [String]] = [:]
        for functionDecl in functionDecls {
            let ignoredParamNames = functionDecl.commentCommands.ignoredParameterNames
            if !ignoredParamNames.isEmpty {
                ignoredParamsByLocation[functionDecl.location] = ignoredParamNames
            }
        }

        let paramsByFunction = UnusedParameterAnalyzer().analyzeEveryFunction(
            file: file.sourceFile,
            syntax: file.syntax,
            locationConverter: file.locationConverter,
            parseProtocols: true
        )

        // A function declared in several `#if` branches is indexed once per configuration with the same USR, and the
        // graph keeps one copy. Its parameters share USRs too, so they are decided per USR group: a parameter is
        // unused only when every copy leaves it unused, and it is attached to the copy the graph
        // kept. Walking the groups in a fixed order keeps the result independent of dictionary order.
        var copiesByUsrs: [Set<String>: [(function: Function, decl: Declaration, unused: Set<Parameter>)]] = [:]
        for (function, params) in paramsByFunction {
            guard let functionDecl = functionDeclsByLocation[function.location] else {
                // The declaration may not exist if the code was not compiled due to build conditions, e.g #if.
                file.logger.debug("Failed to associate indexed function for parameter function '\(function.name)' at \(function.location).")
                continue
            }

            copiesByUsrs[functionDecl.usrs, default: []].append((function, functionDecl, params))
        }

        let orderedGroups = copiesByUsrs.values.map { $0.sorted { $0.decl < $1.decl } }.sorted { $0[0].decl < $1[0].decl }

        var groupedLocations: Set<Location> = []
        for copies in orderedGroups {
            groupedLocations.formUnion(copies.map(\.decl.location))
            let winner = file.graph.withLock { graph in
                copies.first { graph.declaration(withUsr: $0.decl.usrs.sorted()[0]) === $0.decl } ?? copies[0]
            }
            let functionDecl = winner.decl
            // Copies share a signature, not local parameter names, so parameters are matched by position.
            func isUsed(at index: Int) -> Bool {
                copies.contains { copy in
                    copy.function.parameters.indices.contains(index) && !copy.unused.contains(copy.function.parameters[index])
                }
            }
            let ignoredIndexes = Set(copies.flatMap { copy in
                let ignoredNames = ignoredParamsByLocation[copy.decl.location] ?? []
                return copy.function.parameters.indices.filter { ignoredNames.contains(copy.function.parameters[$0].name.text) }
            })

            file.graph.withLock { graph in
                for (index, param) in winner.function.parameters.enumerated() where winner.unused.contains(param) && !isUsed(at: index) {
                    let paramDecl = param.makeDeclaration(withParent: functionDecl)
                    functionDecl.unusedParameters.insert(paramDecl)
                    graph.add(paramDecl)

                    if file.retainsAllDeclarations || (functionDecl.isObjcAccessible && retainObjcAccessible) {
                        graph.markRetained(paramDecl)
                    } else if ignoredIndexes.contains(index) {
                        graph.markRetained(paramDecl)
                        graph.markCommandIgnored(paramDecl, kind: .declaration)
                    }
                }
            }

            // Comment commands are read per copy, but one declaration survives: an ignore command on any copy
            // applies to it, so it carries the commands of the copies the graph did not keep.
            file.graph.withLock { graph in
                for copy in copies where copy.decl !== functionDecl {
                    for command in copy.decl.commentCommands {
                        switch command {
                        case .ignore:
                            functionDecl.commentCommands.insert(command)
                        case .ignoreParameters:
                            functionDecl.commentCommands.insert(command)
                        case .ignoreAll, .override:
                            break
                        }
                    }
                }

                // The winner is tracked, not a copy that equals it, whose parameters it does not own.
                if !functionDecl.commentCommands.ignoredParameterNames.isEmpty {
                    graph.markHasIgnoredParameters(functionDecl)
                }
            }
        }

        // Functions the parameter analysis did not cover keep their ignore command tracked as before.
        file.graph.withLock { graph in
            for functionDecl in functionDecls where !groupedLocations.contains(functionDecl.location) && ignoredParamsByLocation[functionDecl.location] != nil {
                graph.markHasIgnoredParameters(functionDecl)
            }
        }
    }
}
