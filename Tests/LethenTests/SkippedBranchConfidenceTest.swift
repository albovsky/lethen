import Configuration
import Logger
@testable import SourceGraph
import SystemPackage
import XCTest

final class SkippedBranchConfidenceTest: XCTestCase {
    func testSkippedBranchOnlyDowngradesDeclarationsOfTheSameModule() {
        let graph = SourceGraph(configuration: Configuration(), logger: Logger(quiet: true, verbose: false, colorMode: .never))
        graph.addSkippedBranchNames(["Shared": "#if os(Windows) at A.swift:1"], members: [:], construction: [:], modules: ["A"])

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
        graph.addSkippedBranchNames(["Shared": "#if os(Windows) at A.swift:1"], members: [:], construction: [:], modules: ["A"])
        XCTAssertEqual(assess(graph, module: "A", kind: .varInstance).confidence, .certain)

        graph.addSkippedBranchNames(["Shared": "#if os(Windows) at A.swift:1"], members: ["Shared": "#if os(Windows) at A.swift:1"], construction: [:], modules: ["A"])
        XCTAssertEqual(assess(graph, module: "A", kind: .varInstance).confidence, .likely)
    }

    func testEnumCasesNeedAMemberUseAndTypealiasesAreCovered() {
        let graph = SourceGraph(configuration: Configuration(), logger: Logger(quiet: true, verbose: false, colorMode: .never))
        graph.addSkippedBranchNames(["Shared": "#if os(Windows) at A.swift:1"], members: [:], construction: [:], modules: ["A"])
        XCTAssertEqual(assess(graph, module: "A", kind: .enumelement).confidence, .certain)
        XCTAssertEqual(assess(graph, module: "A", kind: .typealias).confidence, .likely)

        // A use inside a pattern reads a property but does not construct an enum case.
        let site = "#if os(Windows) at A.swift:1"
        graph.addSkippedBranchNames(["Shared": site], members: ["Shared": site], construction: [:], modules: ["A"])
        XCTAssertEqual(assess(graph, module: "A", kind: .enumelement).confidence, .certain)
        XCTAssertEqual(assess(graph, module: "A", kind: .varStatic).confidence, .likely)
        graph.addSkippedBranchNames(["Shared": site], members: ["Shared": site], construction: ["Shared": site], modules: ["A"])
        XCTAssertEqual(assess(graph, module: "A", kind: .enumelement).confidence, .likely)
    }

    /// A file built into modules A and B can declare a name in only one of them; a skipped use recorded for
    /// the other module is not a use of it.
    func testDeclarationOnlyIndexedInOneModuleIsNotMatchedAgainstAnotherModulesSkippedUse() {
        let graph = SourceGraph(configuration: Configuration(), logger: Logger(quiet: true, verbose: false, colorMode: .never))
        graph.addSkippedBranchNames(["Shared": "#if os(Windows) at F.swift:1"], members: [:], construction: [:], modules: ["B"])
        let file = SourceFile(path: FilePath("/tmp/F.swift"), modules: ["A", "B"])
        let declaration = Declaration(name: "Shared", kind: .class, usrs: ["s:Shared"], location: Location(file: file, line: 1, column: 1))

        // No recorded module: the file's modules decide, as for a file in one module.
        XCTAssertEqual(graph.assessConfidence(of: declaration).confidence, .likely)
        declaration.indexedModules = ["A"]
        XCTAssertEqual(graph.assessConfidence(of: declaration).confidence, .certain)
        declaration.indexedModules = ["A", "B"]
        XCTAssertEqual(graph.assessConfidence(of: declaration).confidence, .likely)
    }

    private func assess(_ graph: SourceGraph, module: String, kind: Declaration.Kind = .class) -> ConfidenceAssessment {
        let file = SourceFile(path: FilePath("/tmp/\(module).swift"), modules: [module])
        let location = Location(file: file, line: 1, column: 1)
        return graph.assessConfidence(of: Declaration(name: "Shared", kind: kind, usrs: ["s:Shared"], location: location))
    }

    /// `SearchEntry` is used only by `SearchWidget`, whose name appears in a skipped `#if DEBUG` clause: the
    /// clause's uses of `SearchWidget` are not in the graph, and neither are `SearchWidget`'s own, so the
    /// whole chain under the named declaration is likely.
    func testDeclarationReachedOnlyThroughANamedDeclarationIsLikely() {
        let graph = SourceGraph(configuration: Configuration(), logger: Logger(quiet: true, verbose: false, colorMode: .never))
        let file = SourceFile(path: FilePath("/project/Widgets/SearchWidget.swift"), modules: ["Widgets"])
        let widget = Declaration(name: "SearchWidget", kind: .struct, usrs: ["s:SearchWidget"], location: Location(file: file, line: 9, column: 8))
        let entry = Declaration(name: "SearchEntry", kind: .struct, usrs: ["s:SearchEntry"], location: Location(file: file, line: 26, column: 8))
        let reference = Reference(name: "SearchEntry", kind: .normal, declarationKind: .struct, usr: "s:SearchEntry", location: widget.location)
        reference.parent = widget
        graph.add([widget, entry])
        graph.add(reference)
        graph.addSkippedBranchNames(["SearchWidget": "#if DEBUG at Widgets.swift:15"], members: [:], construction: [:], modules: ["Widgets"])

        XCTAssertEqual(graph.assessConfidence(of: widget).confidence, .likely)
        let assessment = graph.assessConfidence(of: entry)
        XCTAssertEqual(assessment.confidence, .likely)
        XCTAssertEqual(assessment.reason, "it is used by SearchWidget, whose name appears in #if DEBUG at Widgets.swift:15, a branch this build did not compile")

        // Named nowhere and reached from nothing that is.
        let other = Declaration(name: "Other", kind: .struct, usrs: ["s:Other"], location: Location(file: file, line: 40, column: 8))
        graph.add(other)
        XCTAssertEqual(graph.assessConfidence(of: other).confidence, .certain)
    }
}
