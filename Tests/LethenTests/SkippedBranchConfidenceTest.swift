import Configuration
import Logger
@testable import SourceGraph
import SystemPackage
import XCTest

final class SkippedBranchConfidenceTest: XCTestCase {
    func testSkippedBranchOnlyDowngradesDeclarationsOfTheSameModule() {
        let graph = SourceGraph(configuration: Configuration(), logger: Logger(quiet: true, verbose: false, colorMode: .never))
        graph.addSkippedBranchNames(["Shared": "#if os(Windows) at A.swift:1"], members: [:], modules: ["A"])

        XCTAssertEqual(assess(graph, module: "A").confidence, .likely)
        XCTAssertEqual(
            assess(graph, module: "A").reason,
            "its name appears in #if os(Windows) at A.swift:1, a branch this build did not compile"
        )
        // The same name in another module's skipped branch is a different declaration.
        XCTAssertEqual(assess(graph, module: "B").confidence, .certain)
    }

    func testMembersNeedAMemberAccessOrCallInTheSkippedBranch() {
        let graph = SourceGraph(configuration: Configuration(), logger: Logger(quiet: true, verbose: false, colorMode: .never))
        graph.addSkippedBranchNames(["Shared": "#if os(Windows) at A.swift:1"], members: [:], modules: ["A"])
        XCTAssertEqual(assess(graph, module: "A", kind: .varInstance).confidence, .certain)

        graph.addSkippedBranchNames(["Shared": "#if os(Windows) at A.swift:1"], members: ["Shared": "#if os(Windows) at A.swift:1"], modules: ["A"])
        XCTAssertEqual(assess(graph, module: "A", kind: .varInstance).confidence, .likely)
    }

    func testEnumCasesNeedAMemberUseAndTypealiasesAreCovered() {
        let graph = SourceGraph(configuration: Configuration(), logger: Logger(quiet: true, verbose: false, colorMode: .never))
        graph.addSkippedBranchNames(["Shared": "#if os(Windows) at A.swift:1"], members: [:], modules: ["A"])
        XCTAssertEqual(assess(graph, module: "A", kind: .enumelement).confidence, .certain)
        XCTAssertEqual(assess(graph, module: "A", kind: .typealias).confidence, .likely)
    }

    private func assess(_ graph: SourceGraph, module: String, kind: Declaration.Kind = .class) -> ConfidenceAssessment {
        let file = SourceFile(path: FilePath("/tmp/\(module).swift"), modules: [module])
        let location = Location(file: file, line: 1, column: 1)
        return graph.assessConfidence(of: Declaration(name: "Shared", kind: kind, usrs: ["s:Shared"], location: location))
    }
}
