import Configuration
@testable import Indexer
import SourceGraph
import XCTest

final class SkippedBranchAnalysisTest: XCTestCase {
    /// A file built into modules `A` and `B` can compile a clause in one and skip it in the other.
    func testEvidenceIsPerModule() throws {
        let source = "#if os(Windows)\nShared.run()\n#endif\n"
        let sourceFile = SourceFile(path: .init("/t/T.swift"), modules: ["A", "B"])
        // `A` compiled the clause: its unit has an occurrence on line 2. `B` has occurrences elsewhere only.
        let occurrences: [String: Set<Location>] = [
            "A": [Location(file: sourceFile, line: 2, column: 1)],
            "B": [Location(file: sourceFile, line: 9, column: 1)],
        ]
        let (file, _, _, evidence) = makeIndexedFile(source: source, modules: ["A", "B"], occurrenceLocations: occurrences)
        try SkippedBranchAnalysis(configuration: Configuration()).apply(to: file)

        let skipped = evidence.snapshot().skippedBranches
        XCTAssertEqual(skipped["B"]?.names["Shared"], "#if os(Windows) at T.swift:1")
        XCTAssertNil(skipped["A"]?.names["Shared"])
    }
}
