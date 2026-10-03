import Configuration
import SourceGraph
import SyntaxAnalysis

/// Marks the references to an enum case that sit inside a pattern (`case .loaded:`), which match the case
/// without constructing it.
struct EnumCasePatternAnalysis: SyntaxAnalysis {
    init(configuration _: Configuration) {}

    func apply(to file: IndexedFile) throws {
        let patterns = EnumCasePatternSyntaxVisitor()
        patterns.walk(file.syntax)
        let patternLocations = patterns.memberPositions.map { file.locationBuilder.location(at: $0) }
        for reference in file.references(at: patternLocations) where reference.declarationKind == .enumelement {
            reference.role = .enumCasePattern
        }
    }
}
