import Dispatch
@testable import SourceGraph
import SystemPackage
import XCTest

final class ConfidenceEvidenceTest: XCTestCase {
    func testMergeKeepsTheSmallestSitePerName() {
        var a = NameSites(names: ["Widget": "B.swift:9"], memberNames: ["load": "B.swift:9"])
        a.merge(NameSites(names: ["Widget": "A.swift:1", "Other": "C.swift:3"], memberNames: ["load": "C.swift:3"], constructionNames: ["load": "C.swift:3"]))
        XCTAssertEqual(a.names, ["Widget": "A.swift:1", "Other": "C.swift:3"])
        XCTAssertEqual(a.memberNames, ["load": "B.swift:9"])
        XCTAssertEqual(a.constructionNames, ["load": "C.swift:3"])
    }

    func testSkippedBranchNamesMergePerModule() {
        var evidence = ConfidenceEvidence()
        evidence.addSkippedBranchNames(NameSites(names: ["Shared": "#if os(Windows) at F.swift:9"]), modules: ["A", "B"])
        evidence.addSkippedBranchNames(NameSites(names: ["Shared": "#if os(Windows) at F.swift:1"]), modules: ["A"])
        XCTAssertEqual(evidence.skippedBranches["A"]?.names["Shared"], "#if os(Windows) at F.swift:1")
        XCTAssertEqual(evidence.skippedBranches["B"]?.names["Shared"], "#if os(Windows) at F.swift:9")
    }

    func testUnscannedTargetNamesNormalizeSharedFilesAndKeepTestableModulesApart() {
        var evidence = ConfidenceEvidence()
        evidence.addUnscannedTargetNames(NameSites(), target: "Ext", sharedSourceFiles: [FilePath("/p/./Shared/W.swift")])
        evidence.addUnscannedTargetNames(NameSites(names: ["W": "Ext/E.swift:2"]), target: "Ext", testableModules: ["App"])
        let names = evidence.unscannedTargets["Ext"]
        XCTAssertEqual(names?.sharedSourceFiles, [FilePath("/p/Shared/W.swift")])
        XCTAssertEqual(names?.all.names["W"], "Ext/E.swift:2")
        XCTAssertEqual(names?.testable["App"]?.names["W"], "Ext/E.swift:2")
        XCTAssertNil(names?.testable["Other"])
    }

    func testMergeOfTwoEvidenceValues() {
        var a = ConfidenceEvidence()
        a.addLiteralTokens(["x"])
        a.clangCoverage = ClangCoverage(unindexedFiles: [])
        var b = ConfidenceEvidence()
        b.addLiteralTokens(["y"])
        b.addSkippedBranchNames(NameSites(names: ["N": "s"]), modules: ["M"])
        b.addUnscannedTargetNames(NameSites(names: ["W": "E.swift:1"]), target: "Ext", sharedSourceFiles: [FilePath("/p/W.swift")], testableModules: ["App"])
        b.clangCoverage = ClangCoverage(unindexedFiles: [FilePath("/p/other.m")])
        a.merge(b)
        XCTAssertEqual(a.literalTokens, ["x", "y"])
        XCTAssertEqual(a.skippedBranches["M"]?.names["N"], "s")
        XCTAssertEqual(a.unscannedTargets["Ext"]?.testable["App"]?.names["W"], "E.swift:1")
        XCTAssertEqual(a.clangCoverage, ClangCoverage(unindexedFiles: []), "the receiver's coverage wins")

        var empty = ConfidenceEvidence()
        empty.merge(b)
        XCTAssertEqual(empty.clangCoverage, b.clangCoverage, "coverage is taken when the receiver has none")
    }

    func testCollectorIsSafeUnderConcurrentAdds() {
        let collector = ConfidenceEvidenceCollector()
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            collector.add { $0.addLiteralTokens(["t\(i)"]) }
        }
        XCTAssertEqual(collector.snapshot().literalTokens.count, 200)
    }
}
