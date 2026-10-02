@testable import SourceGraph
import SystemPackage
import XCTest

final class ClangCoverageTest: XCTestCase {
    private func path(_ name: String) -> FilePath {
        FilePath("/p/\(name)")
    }

    private func assess(_ targets: [ClangCoverage.Target], indexed: [String]) -> ClangCoverage {
        ClangCoverage.assess(targets: targets, indexedFiles: Set(indexed.map(path)))
    }

    private func target(_ name: String, _ files: [String]) -> ClangCoverage.Target {
        .init(name: name, sourceFiles: Set(files.map(path)))
    }

    func testBuiltTargetWhoseObjectiveCFileHasAUnitIsComplete() {
        let coverage = assess([target("App", ["A.swift", "B.m"])], indexed: ["A.swift", "B.m"])
        XCTAssertTrue(coverage.isComplete)
        XCTAssertEqual(coverage.unindexedFiles, [])
    }

    func testBuiltTargetWhoseObjectiveCFileHasNoUnitReportsIt() {
        let coverage = assess([target("App", ["A.swift", "B.m"])], indexed: ["A.swift"])
        XCTAssertFalse(coverage.isComplete)
        XCTAssertEqual(coverage.unindexedFiles, [path("B.m")])
    }

    func testTargetWithNoUnitsIsNotBuiltAndNotMissingAnything() {
        let coverage = assess(
            [target("App", ["A.swift", "B.m"]), target("Unbuilt", ["C.m", "D.swift"])],
            indexed: ["A.swift", "B.m"]
        )
        XCTAssertTrue(coverage.isComplete)
    }

    func testHeadersAndSwiftFilesWithoutUnitsAreNeverReported() {
        let coverage = assess([target("App", ["A.swift", "B.swift", "B.h", "C.hpp", "D.m"])], indexed: ["A.swift", "D.m"])
        XCTAssertTrue(coverage.isComplete)
    }

    func testEveryImplementationExtensionCountsCaseInsensitivelyAndTheOutputIsSorted() {
        let coverage = assess(
            [target("App", ["A.swift", "z.mm", "y.c", "x.cpp", "w.cc", "v.cxx", "u.M", "t.m"])],
            indexed: ["A.swift"]
        )
        XCTAssertEqual(coverage.unindexedFiles, ["t.m", "u.M", "v.cxx", "w.cc", "x.cpp", "y.c", "z.mm"].map(path))
    }

    func testPathsAreComparedNormalized() {
        let coverage = ClangCoverage.assess(
            targets: [.init(name: "App", sourceFiles: [FilePath("/p/sub/../A.swift"), FilePath("/p/sub/../B.m")])],
            indexedFiles: [FilePath("/p/A.swift"), FilePath("/p/B.m")]
        )
        XCTAssertTrue(coverage.isComplete)
    }

    func testUnindexedFilesOfSeveralBuiltTargetsAreCombined() {
        let coverage = assess(
            [target("One", ["A.swift", "B.m"]), target("Two", ["C.swift", "D.m"])],
            indexed: ["A.swift", "C.swift"]
        )
        XCTAssertEqual(coverage.unindexedFiles, [path("B.m"), path("D.m")])
    }

    func testWarningNamesTheCountAndAFewFiles() {
        XCTAssertNil(ClangCoverage(unindexedFiles: []).warning)
        XCTAssertEqual(
            ClangCoverage(unindexedFiles: [path("A.m")]).warning,
            "1 Objective-C file has no index unit (A.m), so declarations accessible from Objective-C are reported as likely rather than certain."
        )
        XCTAssertEqual(
            ClangCoverage(unindexedFiles: ["A.m", "B.m", "C.m", "D.m"].map(path)).warning,
            "4 Objective-C files have no index unit (A.m, B.m, C.m, and 1 more), so declarations accessible from Objective-C are reported as likely rather than certain."
        )
    }
}
