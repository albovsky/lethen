import Configuration
import Foundation

/// Explains why a declaration is reported, used, retained, or ignored, from the source graph after
/// analysis. Used declarations are explained by the shortest chain of references from a retained
/// declaration or from top-level code, following the same edges `UsedDeclarationMarker` follows.
public struct SourceGraphExplainer {
    private let graph: SourceGraph
    private let configuration: Configuration

    public init(graph: SourceGraph, configuration: Configuration) {
        self.graph = graph
        self.configuration = configuration
    }

    /// Declarations whose USR is `query`, or whose name matches it. A name matches with or without its
    /// argument labels (`load` matches `load(from:)`), and a dotted query also matches the names of the
    /// enclosing declarations (`Store.load` matches `load(from:)` declared in `Store`), optionally led by
    /// the module (`App.Store.load`).
    public func declarations(matching query: String) -> [Declaration] {
        if let declaration = graph.declaration(withUsr: query) {
            return [declaration]
        }

        let components = query.split(separator: ".").map(String.init)
        guard let last = components.last else { return [] }

        let enclosing = Array(components.dropLast())
        return graph.allDeclarations
            .filter { declaration in
                guard Self.name(declaration.name, matches: last) else { return false }

                if Self.ancestors(of: declaration, match: enclosing) {
                    return true
                }

                guard let module = enclosing.first, declaration.location.file.modules.contains(module) else { return false }

                return Self.ancestors(of: declaration, match: Array(enclosing.dropFirst()))
            }
            .sorted()
    }

    public func explain(_ declaration: Declaration) -> String {
        var lines = ["\(Self.label(declaration)) at \(declaration.location)"]
        lines.append("  USRs: \(declaration.usrs.sorted().joined(separator: ", "))")
        lines += status(of: declaration).map { "  " + $0 }
        return lines.joined(separator: "\n")
    }

    // MARK: - Status

    private func status(of declaration: Declaration) -> [String] {
        var lines: [String] = []

        if let kind = graph.commandIgnoredDeclarations[declaration] {
            let comment = switch kind {
            case .declaration: "a `// periphery:ignore` comment on it or on an enclosing declaration"
            case .file: "a `// periphery:ignore:all` comment in its file"
            }
            lines.append("Not reported: ignored by \(comment).")
        } else if graph.ignoredDeclarations.contains(declaration) {
            let parent = declaration.parent.map { " (\(Self.label($0)) at \($0.location))" } ?? ""
            lines.append("Not reported separately: its enclosing declaration\(parent) is reported instead.")
        } else if graph.retainedDeclarations.contains(declaration) || graph.retentionSources[declaration] != nil {
            // Members are retained through a reference from their parent, so only a recorded source names the rule.
            lines.append("Used: retained by \(retentionSource(of: declaration)).")
        } else if graph.usedDeclarations.contains(declaration) {
            lines.append("Used, through this chain of references:")
            lines += usageChain(to: declaration).map { "  " + $0 }
        } else {
            lines.append("Reported as unused.")
            lines += unusedReasons(for: declaration)
            lines += hints(for: declaration)
            lines.append(confidenceLine(for: declaration))
            return lines
        }

        let hintLines = hints(for: declaration)
        lines += hintLines
        if !hintLines.isEmpty {
            lines.append(confidenceLine(for: declaration))
        }
        return lines
    }

    private func confidenceLine(for declaration: Declaration) -> String {
        switch graph.assessConfidence(of: declaration).reason {
        case let reason?:
            "Confidence: likely, because \(reason). Check by hand before removing it."
        case nil:
            "Confidence: certain."
        }
    }

    private func retentionSource(of declaration: Declaration) -> String {
        if let mutator = graph.retentionSources[declaration] {
            return mutator
        }

        if graph.commandIgnoredDeclarations[declaration] != nil {
            return "a `// periphery:ignore` comment"
        }

        if declaration.isImplicit {
            return "the indexer, because the compiler generated it"
        }

        if declaration.isObjcAccessible, configuration.retainObjcAccessible {
            return "the indexer, because it is Objective-C accessible and --retain-objc-accessible is set"
        }

        if configuration.retainFilesMatchers.anyMatch(filename: declaration.location.file.path.string) {
            return "the indexer, because its file matches --retain-files"
        }

        return "the indexer"
    }

    private func unusedReasons(for declaration: Declaration) -> [String] {
        let references = graph.references(to: declaration)
        guard !references.isEmpty else {
            return ["No references to its USRs were found in the scanned modules."]
        }

        let referencing = Set(references.compactMap(\.parent)).sorted()
        var lines = ["Referenced only from code that is itself unused:"]
        lines += referencing.prefix(10).map { "  \(Self.label($0)) at \($0.location)" }
        if referencing.count > 10 {
            lines.append("  and \(referencing.count - 10) more")
        }
        return lines
    }

    private func hints(for declaration: Declaration) -> [String] {
        var lines: [String] = []

        if graph.assignOnlyProperties.contains(declaration) {
            lines.append("Reported as assign-only: its value is written but never read.")
        }

        if graph.redundantProtocols[declaration] != nil {
            lines.append("Reported as a redundant protocol: nothing uses it as a type, only conforms to it.")
        }

        if graph.unconstructedEnumCases.contains(declaration) {
            lines.append("Reported as matched but never constructed: every reference to it is a pattern.")
        }

        if let modules = graph.redundantPublicAccessibility[declaration] {
            lines.append("Reported as redundantly public: it is only used within \(modules.sorted().joined(separator: ", ")).")
        }

        return lines
    }

    // MARK: - Usage chain

    private enum Origin {
        case retained
        case topLevel(Reference)
    }

    /// The shortest chain from a retained declaration or top-level code to `target`, as lines.
    private func usageChain(to target: Declaration) -> [String] {
        var previous: [Declaration: (from: Declaration?, via: Reference?, verb: String)] = [:]
        var origins: [Declaration: Origin] = [:]
        var queue: [Declaration] = []

        for declaration in graph.retainedDeclarations.sorted() where previous[declaration] == nil {
            previous[declaration] = (nil, nil, "")
            origins[declaration] = .retained
            queue.append(declaration)
        }

        for reference in graph.rootReferences.sorted() {
            guard let declaration = graph.declaration(withUsr: reference.usr), previous[declaration] == nil else { continue }

            previous[declaration] = (nil, reference, "")
            origins[declaration] = .topLevel(reference)
            queue.append(declaration)
        }

        // Breadth first, so the first time the target is reached is by a shortest chain.
        var index = 0
        while index < queue.count, previous[target] == nil {
            let declaration = queue[index]
            index += 1

            let edges = declaration.references.sorted().map { ($0, "references") }
                + declaration.related.sorted().map { ($0, "is related to") }
            for (reference, verb) in edges {
                guard let next = graph.declaration(withUsr: reference.usr), previous[next] == nil else { continue }

                previous[next] = (declaration, reference, verb)
                queue.append(next)
            }
        }

        guard previous[target] != nil else {
            return ["(no chain found; it was marked used before analysis finished changing the graph)"]
        }

        var chain: [Declaration] = [target]
        while let from = previous[chain[0]]?.from {
            chain.insert(from, at: 0)
        }

        var lines: [String] = []
        switch origins[chain[0]] {
        case .retained:
            lines.append("\(Self.label(chain[0])) at \(chain[0].location), retained by \(retentionSource(of: chain[0]))")
        case let .topLevel(reference):
            let origin = reference.isFromObjectiveC ? "Objective-C code" : "top-level code"
            lines.append("\(origin) at \(reference.location) references \(Self.label(chain[0])) at \(chain[0].location)")
        case nil:
            lines.append("\(Self.label(chain[0])) at \(chain[0].location)")
        }

        for declaration in chain.dropFirst() {
            guard let step = previous[declaration] else { continue }

            let at = step.via.map { " at \($0.location)" } ?? ""
            lines.append("\(step.verb) \(Self.label(declaration))\(at)")
        }

        return lines
    }

    // MARK: - Names

    private static func label(_ declaration: Declaration) -> String {
        "\(declaration.kind.displayName) \(declaration.name)"
    }

    private static func name(_ name: String, matches query: String) -> Bool {
        name == query || name.split(separator: "(", maxSplits: 1).first.map(String.init) == query
    }

    private static func ancestors(of declaration: Declaration, match names: [String]) -> Bool {
        var parent = declaration.parent
        for name in names.reversed() {
            while let current = parent, !Self.name(current.name, matches: name) {
                parent = current.parent
            }

            guard parent != nil else { return false }

            parent = parent?.parent
        }
        return true
    }
}
