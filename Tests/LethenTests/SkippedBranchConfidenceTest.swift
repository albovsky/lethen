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
        evidence.addSkippedBranchNames(NameSites(names: ["Shared": "#if os(Windows) at A.swift:1"], memberNames: [:], constructionNames: [:]), modules: ["A"], file: FilePath("/tmp/A.swift"))

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
        evidence.addSkippedBranchNames(NameSites(names: ["Shared": "#if os(Windows) at A.swift:1"], memberNames: [:], constructionNames: [:]), modules: ["A"], file: FilePath("/tmp/A.swift"))
        XCTAssertEqual(assess(graph, module: "A", kind: .varInstance).confidence, .certain)

        evidence.addSkippedBranchNames(NameSites(names: ["Shared": "#if os(Windows) at A.swift:1"], memberNames: ["Shared": "#if os(Windows) at A.swift:1"], constructionNames: [:]), modules: ["A"], file: FilePath("/tmp/A.swift"))
        XCTAssertEqual(assess(graph, module: "A", kind: .varInstance).confidence, .likely)
    }

    func testEnumCasesNeedAMemberUseAndTypealiasesAreCovered() {
        let graph = SourceGraph(configuration: Configuration(), logger: Logger(quiet: true, verbose: false, colorMode: .never))
        evidence.addSkippedBranchNames(NameSites(names: ["Shared": "#if os(Windows) at A.swift:1"], memberNames: [:], constructionNames: [:]), modules: ["A"], file: FilePath("/tmp/A.swift"))
        XCTAssertEqual(assess(graph, module: "A", kind: .enumelement).confidence, .certain)
        XCTAssertEqual(assess(graph, module: "A", kind: .typealias).confidence, .likely)

        // A use inside a pattern reads a property but does not construct an enum case.
        let site = "#if os(Windows) at A.swift:1"
        evidence.addSkippedBranchNames(NameSites(names: ["Shared": site], memberNames: ["Shared": site], constructionNames: [:]), modules: ["A"], file: FilePath("/tmp/A.swift"))
        XCTAssertEqual(assess(graph, module: "A", kind: .enumelement).confidence, .certain)
        XCTAssertEqual(assess(graph, module: "A", kind: .varStatic).confidence, .likely)
        evidence.addSkippedBranchNames(NameSites(names: ["Shared": site], memberNames: ["Shared": site], constructionNames: ["Shared": site]), modules: ["A"], file: FilePath("/tmp/A.swift"))
        XCTAssertEqual(assess(graph, module: "A", kind: .enumelement).confidence, .likely)
    }

    /// A file built into modules A and B can declare a name in only one of them; a skipped use recorded for
    /// the other module is not a use of it.
    func testDeclarationOnlyIndexedInOneModuleIsNotMatchedAgainstAnotherModulesSkippedUse() {
        let graph = SourceGraph(configuration: Configuration(), logger: Logger(quiet: true, verbose: false, colorMode: .never))
        evidence.addSkippedBranchNames(NameSites(names: ["Shared": "#if os(Windows) at F.swift:1"], memberNames: [:], constructionNames: [:]), modules: ["B"], file: FilePath("/tmp/F.swift"))
        let file = SourceFile(path: FilePath("/tmp/F.swift"), modules: ["A", "B"])
        let declaration = Declaration(name: "Shared", kind: .class, usrs: ["s:Shared"], location: Location(file: file, line: 1, column: 1))

        // No recorded module: the file's modules decide, as for a file in one module.
        XCTAssertEqual(assessor(graph).assess(declaration).confidence, .likely)
        declaration.indexedModules = ["A"]
        XCTAssertEqual(assessor(graph).assess(declaration).confidence, .certain)
        declaration.indexedModules = ["A", "B"]
        XCTAssertEqual(assessor(graph).assess(declaration).confidence, .likely)
    }

    private func assess(
        _ graph: SourceGraph,
        module: String,
        kind: Declaration.Kind = .class,
        name: String = "Shared",
        accessibility: Accessibility = .internal
    ) -> ConfidenceAssessment {
        let file = SourceFile(path: FilePath("/tmp/\(module).swift"), modules: [module])
        let location = Location(file: file, line: 1, column: 1)
        let declaration = Declaration(name: name, kind: kind, usrs: ["s:\(name)"], location: location)
        declaration.accessibility = .init(value: accessibility, isExplicit: true)
        return assessor(graph).assess(declaration)
    }

    /// A `private` or `fileprivate` declaration is invisible to every other file, so a clause elsewhere that
    /// spells its name names some other declaration; a clause of its own file names it as before.
    func testOnlyItsOwnFilesClauseNamesAFilePrivateDeclaration() {
        let graph = SourceGraph(configuration: Configuration(), logger: Logger(quiet: true, verbose: false, colorMode: .never))
        let elsewhere = "#if os(Linux) at Other.swift:3"
        evidence.addSkippedBranchNames(
            NameSites(names: ["Shared": elsewhere], spellings: ["Shared": [.init(): elsewhere]]),
            modules: ["A"],
            file: FilePath("/tmp/Other.swift")
        )

        XCTAssertEqual(assess(graph, module: "A", kind: .varGlobal).confidence, .likely)
        XCTAssertEqual(assess(graph, module: "A", kind: .varGlobal, accessibility: .private).confidence, .certain)
        XCTAssertEqual(assess(graph, module: "A", kind: .varGlobal, accessibility: .fileprivate).confidence, .certain)

        // The same name in a clause of the declaration's own file, which can see it.
        let own = "#if os(Windows) at A.swift:5"
        evidence.addSkippedBranchNames(
            NameSites(names: ["Shared": own], spellings: ["Shared": [.init(): own]]),
            modules: ["A"],
            file: FilePath("/tmp/A.swift")
        )
        XCTAssertEqual(assess(graph, module: "A", kind: .varGlobal, accessibility: .private).reason, "its name appears in \(own), a branch this build did not compile")
        // An internal declaration still takes the smallest site of the whole module, here the other file's.
        XCTAssertEqual(assess(graph, module: "A", kind: .varGlobal).reason, "its name appears in \(elsewhere), a branch this build did not compile")
    }

    /// Nothing reaches a global, a free function or a top-level type through a value or a type, so a member
    /// access such as `self.logger` names a member of something else, not a declaration at file scope.
    func testAMemberAccessDoesNotNameAFileScopeDeclaration() {
        let graph = SourceGraph(configuration: Configuration(), logger: Logger(quiet: true, verbose: false, colorMode: .never))
        let site = "#if !DEBUG at Storage.swift:9"
        let access = NameSites.Spelling(isMember: true, isMemberAccess: true)
        evidence.addSkippedBranchNames(
            NameSites(names: ["logger": site], memberNames: ["logger": site], spellings: ["logger": [access: site]]),
            modules: ["A"],
            file: FilePath("/tmp/A.swift")
        )

        for kind in [Declaration.Kind.varGlobal, .functionFree, .class, .typealias, .functionOperatorInfix] {
            XCTAssertEqual(assess(graph, module: "A", kind: kind, name: "logger").confidence, .certain, "\(kind)")
        }
        // Control: the member the clause really spells keeps the hint.
        XCTAssertEqual(assess(graph, module: "A", kind: .varInstance, name: "logger").confidence, .likely)

        // A module can qualify one of its own file-scope declarations: `App.logger` names the global.
        let qualified = "#if !DEBUG at Storage.swift:1"
        evidence.addSkippedBranchNames(
            NameSites(
                names: ["logger": qualified],
                memberNames: ["logger": qualified],
                spellings: ["logger": [.init(receiver: "A", isMember: true, isMemberAccess: true): qualified]]
            ),
            modules: ["A"],
            file: FilePath("/tmp/A.swift")
        )
        XCTAssertEqual(assess(graph, module: "A", kind: .varGlobal, name: "logger").confidence, .likely)
    }

    /// A bare identifier is how a global is named, and the control for both rules above: the evidence of the
    /// other file still downgrades it.
    func testABareIdentifierInAnotherFilesClauseNamesAnInternalGlobal() {
        let graph = SourceGraph(configuration: Configuration(), logger: Logger(quiet: true, verbose: false, colorMode: .never))
        let site = "#if !DEBUG at Storage.swift:9"
        evidence.addSkippedBranchNames(
            NameSites(names: ["logger": site], spellings: ["logger": [.init(): site]]),
            modules: ["A"],
            file: FilePath("/tmp/Storage.swift")
        )

        XCTAssertEqual(assess(graph, module: "A", kind: .varGlobal, name: "logger").confidence, .likely)
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
        evidence.addSkippedBranchNames(NameSites(names: ["SearchWidget": "#if DEBUG at Widgets.swift:15"], memberNames: [:], constructionNames: [:]), modules: ["Widgets"], file: FilePath("/project/Widgets/Widgets.swift"))

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
