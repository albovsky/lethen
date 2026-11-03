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

    func testSkippedBranchNamesMergePerModuleAndKeepEachFileApart() {
        var evidence = ConfidenceEvidence()
        evidence.addSkippedBranchNames(NameSites(names: ["Shared": "#if os(Windows) at F.swift:9"]), modules: ["A", "B"], file: FilePath("/p/F.swift"))
        evidence.addSkippedBranchNames(NameSites(names: ["Shared": "#if os(Windows) at G.swift:1"]), modules: ["A"], file: FilePath("/p/./G.swift"))
        XCTAssertEqual(evidence.skippedBranches["A"]?.all.names["Shared"], "#if os(Windows) at F.swift:9")
        XCTAssertEqual(evidence.skippedBranches["B"]?.all.names["Shared"], "#if os(Windows) at F.swift:9")
        // Each file keeps only its own clauses, under a normalized path, so a `private` declaration is
        // matched against the file that can see it and no other.
        XCTAssertEqual(evidence.skippedBranches["A"]?.byFile[FilePath("/p/F.swift")]?.names["Shared"], "#if os(Windows) at F.swift:9")
        XCTAssertEqual(evidence.skippedBranches["A"]?.byFile[FilePath("/p/G.swift")]?.names["Shared"], "#if os(Windows) at G.swift:1")
        XCTAssertNil(evidence.skippedBranches["B"]?.byFile[FilePath("/p/G.swift")])
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

    func testCollectorIsSafeUnderConcurrentAdds() {
        let collector = ConfidenceEvidenceCollector()
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            collector.add { $0.addLiteralTokens(["t\(i)"]) }
        }
        XCTAssertEqual(collector.snapshot().literalTokens.count, 200)
    }
}
