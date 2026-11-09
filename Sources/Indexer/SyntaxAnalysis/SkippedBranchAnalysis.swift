import Configuration
import SourceGraph
import SwiftSyntax
import SyntaxAnalysis

/// Records the names used in `#if` clauses the build did not compile, per module, as evidence for confidence.
/// A file built into several modules can compile different clauses in each, so the visitor runs once per
/// module with that module's occurrences. A module with no occurrence in the file, such as a file
/// conditionally compiled out entirely, has no evidence for any clause.
struct SkippedBranchAnalysis: SyntaxAnalysis {
    init(configuration _: Configuration) {}

    func apply(to file: IndexedFile) throws {
        var typeQualifiers: Set<String>?
        func isTypeQualifier(_ name: String) -> Bool {
            if typeQualifiers == nil { typeQualifiers = Self.importNamesUsedAsTypes(in: file) }
            return typeQualifiers?.contains(name) == true
        }

        for module in file.sourceFile.modules.sorted() {
            let skippedBranches = SkippedConditionalBranchVisitor(
                locationBuilder: file.locationBuilder,
                evidence: file.occurrenceLocations[module] ?? [],
                isTypeQualifier: isTypeQualifier
            )
            skippedBranches.walk(file.syntax)
            file.evidence.add {
                $0.addSkippedBranchNames(
                    NameSites(
                        names: skippedBranches.names,
                        memberNames: skippedBranches.memberNames,
                        constructionNames: skippedBranches.constructionNames,
                        spellings: skippedBranches.spellings
                    ),
                    modules: [module],
                    file: file.sourceFile.path
                )
            }
        }
    }

    /// A module's name can also be a type name. Only count an indexed type reference that uses that name
    /// without qualification in this file: `SDK.self` resolves `SDK` as a type, but `Other.SDK.self` does not.
    private static func importNamesUsedAsTypes(in file: IndexedFile) -> Set<String> {
        let imports = Set(file.sourceFile.importStatements.map(\.module))
        var names: Set<String> = []
        for (location, references) in file.referencesByLocation {
            for reference in references where imports.contains(reference.name) && !names.contains(reference.name) {
                guard reference.declarationKind.isExtendableKind || reference.declarationKind == .typealias else { continue }

                let position = file.locationConverter.position(ofLine: location.line, column: location.column)
                guard let token = file.syntax.token(at: position), token.identifier?.name == reference.name else { continue }

                if let use = token.parent?.as(DeclReferenceExprSyntax.self) {
                    if use.parent?.as(MemberAccessExprSyntax.self)?.declName.id == use.id { continue }
                } else if token.parent?.is(IdentifierTypeSyntax.self) != true {
                    continue
                }
                names.insert(reference.name)
            }
        }
        return names
    }
}
