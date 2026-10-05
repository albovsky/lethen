import Configuration
import SyntaxAnalysis

/// Records the string literals that can name a declaration at run time, as evidence for confidence: the
/// identifier-like words of every symbol-shaped literal (a selector whole), and the identifiers a reflection or dynamic-lookup
/// call receives, each with its call site. Neither touches the file's declarations or references.
struct StringLiteralAnalysis: SyntaxAnalysis {
    init(configuration _: Configuration) {}

    func apply(to file: IndexedFile) throws {
        let literals = StringLiteralTokenVisitor()
        literals.walk(file.syntax)
        let reflection = ReflectionLiteralVisitor(locationBuilder: file.locationBuilder)
        reflection.walk(file.syntax)
        file.evidence.add {
            $0.addLiteralTokens(literals.tokens)
            $0.addLiteralSelectors(literals.selectors)
            $0.addReflectionSites(reflection.sites)
            $0.addReflectionSelectorSites(reflection.selectorSites)
        }
    }
}
