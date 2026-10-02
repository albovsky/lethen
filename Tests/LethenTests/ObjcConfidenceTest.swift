import Configuration
import Logger
@testable import SourceGraph
import SystemPackage
import XCTest

final class ObjcConfidenceTest: XCTestCase {
    private func files(_ names: [String]) -> ClangCoverage {
        ClangCoverage(unindexedFiles: names.map { FilePath("/p/\($0)") })
    }

    private func assess(
        coverage: ClangCoverage?,
        isObjcAccessible: Bool = true,
        configuration: Configuration = Configuration(),
        literalTokens: Set<String> = []
    ) -> ConfidenceAssessment {
        let graph = SourceGraph(configuration: configuration, logger: Logger(quiet: true, verbose: false, colorMode: .never))
        graph.setClangCoverage(coverage)
        graph.addLiteralTokens(literalTokens)
        let file = SourceFile(path: FilePath("/p/A.swift"), modules: ["A"])
        let declaration = Declaration(name: "exposed()", kind: .functionMethodInstance, usrs: ["s:exposed"], location: Location(file: file, line: 1, column: 1))
        declaration.isObjcAccessible = isObjcAccessible
        return graph.assessConfidence(of: declaration)
    }

    func testUnknownCoverageIsLikely() {
        let assessment = assess(coverage: nil)
        XCTAssertEqual(assessment.confidence, .likely)
        XCTAssertTrue(assessment.reason?.contains("cannot tell whether every Objective-C file") == true, assessment.reason ?? "")
    }

    func testOneUnindexedFileIsNamedInTheSingular() {
        let assessment = assess(coverage: files(["Foo.m"]))
        XCTAssertEqual(assessment.confidence, .likely)
        XCTAssertEqual(assessment.reason, "it is accessible from Objective-C, and 1 Objective-C file (Foo.m) has no index unit, so a reference made from it would be missed")
    }

    func testSeveralUnindexedFilesListThreeNamesAndCountTheRest() {
        let assessment = assess(coverage: files(["A.m", "B.m", "C.m", "D.m", "E.m"]))
        XCTAssertEqual(assessment.confidence, .likely)
        XCTAssertEqual(assessment.reason, "it is accessible from Objective-C, and 5 Objective-C files (A.m, B.m, C.m, and 2 more) have no index unit, so a reference made from them would be missed")
    }

    func testThreeUnindexedFilesListAllOfThem() {
        XCTAssertEqual(
            assess(coverage: files(["A.m", "B.m", "C.m"])).reason,
            "it is accessible from Objective-C, and 3 Objective-C files (A.m, B.m, C.m) have no index unit, so a reference made from them would be missed"
        )
    }

    func testCompleteCoverageIsCertain() {
        let assessment = assess(coverage: files([]))
        XCTAssertEqual(assessment.confidence, .certain)
        XCTAssertNil(assessment.reason)
    }

    func testCompleteCoverageStillDowngradesANameInAStringLiteral() {
        let assessment = assess(coverage: files([]), literalTokens: ["exposed"])
        XCTAssertEqual(assessment.confidence, .likely)
        XCTAssertEqual(assessment.reason, "its name appears in a string literal")
    }

    func testRetainObjcAccessibleKeepsTheOldPathCertain() {
        let configuration = Configuration()
        configuration.retainObjcAccessible = true
        XCTAssertEqual(assess(coverage: nil, configuration: configuration).confidence, .certain)
        XCTAssertEqual(assess(coverage: files(["A.m"]), configuration: configuration).confidence, .certain)
    }

    func testDeclarationNotAccessibleFromObjectiveCIsCertainWhateverTheCoverage() {
        XCTAssertEqual(assess(coverage: nil, isObjcAccessible: false).confidence, .certain)
        XCTAssertEqual(assess(coverage: files(["A.m"]), isObjcAccessible: false).confidence, .certain)
    }
}
