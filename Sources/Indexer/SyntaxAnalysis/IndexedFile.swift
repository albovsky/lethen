import Logger
import SourceGraph
import SwiftSyntax
import SyntaxAnalysis

/// One Swift file after index phase one, parsed once, for the syntax analyses of phase two.
struct IndexedFile {
    let sourceFile: SourceFile
    let syntax: SourceFileSyntax
    let locationBuilder: SourceLocationBuilder
    let locationConverter: SourceLocationConverter
    /// The file's declarations from the index, in index order.
    let declarations: [Declaration]
    /// The comment commands in the leading trivia of the file, such as `periphery:ignore:all`.
    let fileCommands: [CommentCommand]
    /// The file's references from the index, by their location. Several references can share one location.
    let referencesByLocation: [Location: Set<Reference>]
    /// Locations of every index occurrence in the file, by the module whose unit recorded them. A file built
    /// into several modules can compile different `#if` clauses in each.
    let occurrenceLocations: [String: Set<Location>]
    /// Whether every declaration of the file is retained, as for a file named by `--retain-files`.
    let retainsAllDeclarations: Bool
    let graph: SourceGraphMutex
    let logger: ContextualLogger
    /// Where an analysis records what makes a report less certain.
    let evidence: ConfidenceEvidenceCollector

    /// The references at the location; empty when no syntax node of the index reaches it, such as in code
    /// compiled out by `#if`.
    func references(at location: Location) -> Set<Reference> {
        referencesByLocation[location, default: []]
    }

    func references(at locations: some Sequence<Location>) -> Set<Reference> {
        locations.reduce(into: []) { $0.formUnion(references(at: $1)) }
    }
}
