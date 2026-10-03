import SourceGraph
import SwiftSyntax
import SyntaxAnalysis

/// One Swift file after index phase one, parsed once, for the syntax analyses of phase two.
struct IndexedFile {
    let syntax: SourceFileSyntax
    let locationBuilder: SourceLocationBuilder
    /// The file's references from the index, by their location. Several references can share one location.
    let referencesByLocation: [Location: Set<Reference>]

    /// The references at the location; empty when no syntax node of the index reaches it, such as in code
    /// compiled out by `#if`.
    func references(at location: Location) -> Set<Reference> {
        referencesByLocation[location, default: []]
    }

    func references(at locations: some Sequence<Location>) -> Set<Reference> {
        locations.reduce(into: []) { $0.formUnion(references(at: $1)) }
    }
}
