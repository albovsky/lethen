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

    func testSelectorShapedLiteralsAreKeptWholeAndNotSplit() throws {
        let source = "let a = \"setTitle:forState:\"\nlet b = \"user.name\"\nlet c = \"a:b\"\nlet d = \":\"\n"
        let (file, _, _, evidence) = makeIndexedFile(source: source)
        try StringLiteralAnalysis(configuration: Configuration()).apply(to: file)

        XCTAssertEqual(evidence.snapshot().literalSelectors, ["setTitle:forState:", "a:b"])
        // A key path keeps matching by its pieces; a selector names no piece of itself.
        XCTAssertEqual(evidence.snapshot().literalTokens, ["user", "name"])
    }

    func testSelectorPassedToAReflectionCallIsRecordedWholeAndNotSplit() throws {
        let source = "let a = NSSelectorFromString(\"load:\")\nlet b = NSSelectorFromString(\"load\")\n"
        let (file, _, _, evidence) = makeIndexedFile(source: source)
        try StringLiteralAnalysis(configuration: Configuration()).apply(to: file)

        XCTAssertEqual(evidence.snapshot().reflectionSelectorSites, ["load:": "NSSelectorFromString at T.swift:1"])
        XCTAssertEqual(evidence.snapshot().reflectionSites, ["load": "NSSelectorFromString at T.swift:2"])
        XCTAssertEqual(evidence.snapshot().literalSelectors, ["load:"])
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
