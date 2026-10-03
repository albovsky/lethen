import Configuration
import Logger
@testable import SourceGraph
import SystemPackage
import XCTest

final class SkippedBranchConfidenceTest: XCTestCase {
    private var evidence = ConfidenceEvidence()

    /// A fresh assessor over the evidence recorded so far: it memoizes, so one built earlier would not see later evidence.
    private func assessor(_ graph: SourceGraph) -> ConfidenceAssessor {
        ConfidenceAssessor(evidence: evidence, graph: graph, configuration: Configuration())
    }

    func testSkippedBranchOnlyDowngradesDeclarationsOfTheSameModule() {
        let graph = SourceGraph(configuration: Configuration(), logger: Logger(quiet: true, verbose: false, colorMode: .never))
        evidence.addSkippedBranchNames(NameSites(names: ["Shared": "#if os(Windows) at A.swift:1"], memberNames: [:], constructionNames: [:]), modules: ["A"])

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
        evidence.addSkippedBranchNames(NameSites(names: ["Shared": "#if os(Windows) at A.swift:1"], memberNames: [:], constructionNames: [:]), modules: ["A"])
        XCTAssertEqual(assess(graph, module: "A", kind: .varInstance).confidence, .certain)

        evidence.addSkippedBranchNames(NameSites(names: ["Shared": "#if os(Windows) at A.swift:1"], memberNames: ["Shared": "#if os(Windows) at A.swift:1"], constructionNames: [:]), modules: ["A"])
        XCTAssertEqual(assess(graph, module: "A", kind: .varInstance).confidence, .likely)
    }

    func testEnumCasesNeedAMemberUseAndTypealiasesAreCovered() {
        let graph = SourceGraph(configuration: Configuration(), logger: Logger(quiet: true, verbose: false, colorMode: .never))
        evidence.addSkippedBranchNames(NameSites(names: ["Shared": "#if os(Windows) at A.swift:1"], memberNames: [:], constructionNames: [:]), modules: ["A"])
        XCTAssertEqual(assess(graph, module: "A", kind: .enumelement).confidence, .certain)
        XCTAssertEqual(assess(graph, module: "A", kind: .typealias).confidence, .likely)

        // A use inside a pattern reads a property but does not construct an enum case.
        let site = "#if os(Windows) at A.swift:1"
        evidence.addSkippedBranchNames(NameSites(names: ["Shared": site], memberNames: ["Shared": site], constructionNames: [:]), modules: ["A"])
        XCTAssertEqual(assess(graph, module: "A", kind: .enumelement).confidence, .certain)
        XCTAssertEqual(assess(graph, module: "A", kind: .varStatic).confidence, .likely)
        evidence.addSkippedBranchNames(NameSites(names: ["Shared": site], memberNames: ["Shared": site], constructionNames: ["Shared": site]), modules: ["A"])
        XCTAssertEqual(assess(graph, module: "A", kind: .enumelement).confidence, .likely)
    }

    /// A file built into modules A and B can declare a name in only one of them; a skipped use recorded for
    /// the other module is not a use of it.
    func testDeclarationOnlyIndexedInOneModuleIsNotMatchedAgainstAnotherModulesSkippedUse() {
        let graph = SourceGraph(configuration: Configuration(), logger: Logger(quiet: true, verbose: false, colorMode: .never))
        evidence.addSkippedBranchNames(NameSites(names: ["Shared": "#if os(Windows) at F.swift:1"], memberNames: [:], constructionNames: [:]), modules: ["B"])
        let file = SourceFile(path: FilePath("/tmp/F.swift"), modules: ["A", "B"])
        let declaration = Declaration(name: "Shared", kind: .class, usrs: ["s:Shared"], location: Location(file: file, line: 1, column: 1))

        // No recorded module: the file's modules decide, as for a file in one module.
        XCTAssertEqual(assessor(graph).assess(declaration).confidence, .likely)
        declaration.indexedModules = ["A"]
        XCTAssertEqual(assessor(graph).assess(declaration).confidence, .certain)
        declaration.indexedModules = ["A", "B"]
        XCTAssertEqual(assessor(graph).assess(declaration).confidence, .likely)
    }

    private func assess(_ graph: SourceGraph, module: String, kind: Declaration.Kind = .class) -> ConfidenceAssessment {
        let file = SourceFile(path: FilePath("/tmp/\(module).swift"), modules: [module])
        let location = Location(file: file, line: 1, column: 1)
        return assessor(graph).assess(Declaration(name: "Shared", kind: kind, usrs: ["s:Shared"], location: location))
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
        evidence.addSkippedBranchNames(NameSites(names: ["SearchWidget": "#if DEBUG at Widgets.swift:15"], memberNames: [:], constructionNames: [:]), modules: ["Widgets"])

        XCTAssertEqual(assessor(graph).assess(widget).confidence, .likely)
        let assessment = assessor(graph).assess(entry)
        XCTAssertEqual(assessment.confidence, .likely)
        XCTAssertEqual(assessment.reason, "it is used by SearchWidget, whose name appears in #if DEBUG at Widgets.swift:15, a branch this build did not compile")

        // Named nowhere and reached from nothing that is.
        let other = Declaration(name: "Other", kind: .struct, usrs: ["s:Other"], location: Location(file: file, line: 40, column: 8))
        graph.add(other)
        XCTAssertEqual(assessor(graph).assess(other).confidence, .certain)
    }
}
