import Configuration
@testable import Indexer
import XCTest

final class StringLiteralAnalysisTest: XCTestCase {
    func testIdentifierLikeWordsInLiteralsBecomeEvidence() throws {
        let source = "let a = \"loadData\"\nlet b = \"MyApp.Cache\"\nlet c = \"loadMore from cache\"\n"
        let (file, _, _, evidence) = makeIndexedFile(source: source)
        try StringLiteralAnalysis(configuration: Configuration()).apply(to: file)

        // The prose literal, with spaces, is not symbol-shaped.
        XCTAssertEqual(evidence.snapshot().literalTokens, ["loadData", "MyApp", "Cache"])
    }

    func testReflectionCallsRecordTheirSite() throws {
        let source = "let a = \"plain\"\nlet b = NSClassFromString(\"MyApp.Store\")\n"
        let (file, _, _, evidence) = makeIndexedFile(source: source)
        try StringLiteralAnalysis(configuration: Configuration()).apply(to: file)

        XCTAssertEqual(evidence.snapshot().reflectionSites, [
            "MyApp": "NSClassFromString at T.swift:2",
            "Store": "NSClassFromString at T.swift:2",
        ])
    }
}
