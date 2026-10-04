import Configuration
import SourceGraph
import SyntaxAnalysis

/// Records the names used in `#if` clauses the build did not compile, per module, as evidence for confidence.
/// A file built into several modules can compile different clauses in each, so the visitor runs once per
/// module with that module's occurrences. A module with no occurrence in the file, such as a file
/// conditionally compiled out entirely, has no evidence for any clause.
struct SkippedBranchAnalysis: SyntaxAnalysis {
    init(configuration _: Configuration) {}

    func apply(to file: IndexedFile) throws {
        for module in file.sourceFile.modules.sorted() {
            let skippedBranches = SkippedConditionalBranchVisitor(
                locationBuilder: file.locationBuilder,
                evidence: file.occurrenceLocations[module] ?? []
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
                    modules: [module]
                )
            }
        }
    }
}
