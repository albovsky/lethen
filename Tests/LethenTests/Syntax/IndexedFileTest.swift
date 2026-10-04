@testable import Indexer
import SourceGraph
import XCTest

final class IndexedFileTest: XCTestCase {
    func testReferencesAtAnUnknownLocationAreEmpty() {
        let (file, sourceFile, _) = makeIndexedFile(source: "let a = 1\n", references: [(1, 5, .varGlobal, "a")])
        XCTAssertEqual(file.references(at: Location(file: sourceFile, line: 9, column: 9)), [])
        XCTAssertEqual(file.references(at: Location(file: sourceFile, line: 1, column: 5)).count, 1)
    }

    func testReferencesAtSeveralLocationsAreTheirUnion() {
        let (file, sourceFile, _) = makeIndexedFile(source: "let a = 1\nlet b = 2\n", references: [(1, 5, .varGlobal, "a"), (2, 5, .varGlobal, "b")])
        let locations = [1, 2, 3].map { Location(file: sourceFile, line: $0, column: 5) }
        XCTAssertEqual(Set(file.references(at: locations).map(\.name)), ["a", "b"])
    }
}
