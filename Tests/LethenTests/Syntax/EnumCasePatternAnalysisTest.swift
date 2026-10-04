import Configuration
@testable import Indexer
import SourceGraph
import XCTest

final class EnumCasePatternAnalysisTest: XCTestCase {
    func testEnumCaseReferenceInsideAPatternGetsThePatternRole() throws {
        let source = "switch v {\ncase .matched: break\ndefault: break\n}\n_ = Kind.constructed\n"
        let (file, _, _) = makeIndexedFile(source: source, references: [
            (2, 7, .enumelement, "matched"), // inside the pattern
            (5, 10, .enumelement, "constructed"), // a construction, not a pattern
            (2, 7, .varGlobal, "notACase"), // same location as a pattern, not an enum case
            (9, 1, .enumelement, "nowhere"), // no syntax at this location
        ])
        try EnumCasePatternAnalysis(configuration: Configuration()).apply(to: file)

        let roles = Dictionary(uniqueKeysWithValues: file.referencesByLocation.values.flatMap(\.self).map { ($0.name, $0.role) })
        XCTAssertEqual(roles["matched"], .enumCasePattern)
        XCTAssertEqual(roles["constructed"], .unknown)
        XCTAssertEqual(roles["notACase"], .unknown)
        XCTAssertEqual(roles["nowhere"], .unknown)
    }
}
