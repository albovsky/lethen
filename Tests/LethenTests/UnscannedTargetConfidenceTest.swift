import Configuration
import Logger
@testable import SourceGraph
import SystemPackage
import XCTest

final class UnscannedTargetConfidenceTest: XCTestCase {
    private let site = "Widgets/Extension/Widgets.swift:15"
    private let place = "Widgets/Extension/Widgets.swift:15, a file of target WidgetsExtension, which the scanned schemes do not build"
    private let sharedFile = FilePath("/project/Shared/Widget.swift")
    private let otherFile = FilePath("/project/App/Other.swift")

    private var evidence = ConfidenceEvidence()

    /// A fresh assessor over the evidence recorded so far: it memoizes, so one built earlier would not see later evidence.
    private func assessor(_ graph: SourceGraph) -> ConfidenceAssessor {
        ConfidenceAssessor(evidence: evidence, graph: graph, configuration: Configuration())
    }

    private func makeGraph() -> SourceGraph {
        SourceGraph(configuration: Configuration(), logger: Logger(quiet: true, verbose: false, colorMode: .never))
    }

    private func declaration(
        _ name: String,
        kind: Declaration.Kind = .struct,
        in path: FilePath? = nil,
        accessibility: Accessibility = .internal,
        parent: Declaration? = nil,
        line: Int = 1
    ) -> Declaration {
        let file = SourceFile(path: path ?? sharedFile, modules: ["App"])
        let declaration = Declaration(name: name, kind: kind, usrs: ["s:\(kind.rawValue):\(name)"], location: Location(file: file, line: line, column: 1))
        declaration.accessibility = DeclarationAccessibility(value: accessibility, isExplicit: true)
        declaration.parent = parent
        return declaration
    }

    private func use(_ names: [String], members: [String] = [], construction: [String] = []) {
        evidence.addUnscannedTargetNames(
            NameSites(
                names: Dictionary(uniqueKeysWithValues: names.map { ($0, site) }),
                memberNames: Dictionary(uniqueKeysWithValues: members.map { ($0, site) }),
                constructionNames: Dictionary(uniqueKeysWithValues: construction.map { ($0, site) })
            ),
            target: "WidgetsExtension",
            sharedSourceFiles: [sharedFile]
        )
    }

    func testNameInAFileTheTargetCompilesIsLikely() {
        let graph = makeGraph()
        use(["Widget"])

        let assessment = assessor(graph).assess(declaration("Widget"))
        XCTAssertEqual(assessment.confidence, .likely)
        XCTAssertEqual(assessment.reason, "its name appears in \(place)")
    }

    func testInternalDeclarationOutsideTheTargetsFilesIsCertain() {
        let graph = makeGraph()
        use(["Widget"])

        XCTAssertEqual(assessor(graph).assess(declaration("Widget", in: otherFile)).confidence, .certain)
    }

    func testPublicDeclarationIsLikelyWhereverItIsDeclared() {
        let graph = makeGraph()
        use(["Widget"])

        XCTAssertEqual(assessor(graph).assess(declaration("Widget", in: otherFile, accessibility: .public)).confidence, .likely)
        XCTAssertEqual(assessor(graph).assess(declaration("Widget", in: otherFile, accessibility: .open)).confidence, .likely)
    }

    /// A public member of an internal type is not visible outside its module.
    func testPublicMemberOfAnInternalTypeIsNotVisible() {
        let graph = makeGraph()
        use(["run"], members: ["run"])
        let type = declaration("Hidden", kind: .class, in: otherFile)
        let member = declaration("run()", kind: .functionMethodInstance, in: otherFile, accessibility: .public, parent: type)

        XCTAssertEqual(assessor(graph).assess(member).confidence, .certain)
    }

    /// A member is reached through its type, so a target that uses `.shared` or `.init` on some other type
    /// does not use this one; naming the type as well is what makes the member reachable.
    func testMembersNeedTheirTypeNamedByTheSameTarget() {
        let graph = makeGraph()
        let type = declaration("Store", kind: .class, in: otherFile, accessibility: .public)
        let member = declaration("shared", kind: .varStatic, in: otherFile, accessibility: .public, parent: type)
        let initializer = declaration("init(url:)", kind: .functionConstructor, in: otherFile, accessibility: .public, parent: type)

        use(["shared", "init"], members: ["shared", "init"], construction: ["shared", "init"])
        XCTAssertEqual(assessor(graph).assess(member).confidence, .certain)
        XCTAssertEqual(assessor(graph).assess(initializer).confidence, .certain)

        use(["Store"])
        XCTAssertEqual(assessor(graph).assess(member).confidence, .likely)
        XCTAssertEqual(assessor(graph).assess(initializer).confidence, .likely)
    }

    /// A member of a type in a file the target compiles is reached through the type there too.
    func testMembersOfASharedFileNeedTheirTypeNamedAsWell() {
        let graph = makeGraph()
        let type = declaration("Widget", kind: .struct)
        let member = declaration("entry", kind: .varInstance, parent: type)
        use(["entry"], members: ["entry"])
        XCTAssertEqual(assessor(graph).assess(member).confidence, .certain)

        use(["Widget"])
        XCTAssertEqual(assessor(graph).assess(member).confidence, .likely)
    }

    /// The shared file is not read, so a matching name is in another file, which cannot reach a private or
    /// fileprivate declaration.
    func testFileScopedDeclarationsInASharedFileStayCertain() {
        let graph = makeGraph()
        use(["Widget", "Helper"])

        XCTAssertEqual(assessor(graph).assess(declaration("Widget", accessibility: .private)).confidence, .certain)
        XCTAssertEqual(assessor(graph).assess(declaration("Widget", accessibility: .fileprivate)).confidence, .certain)
        XCTAssertEqual(assessor(graph).assess(declaration("Helper", accessibility: .internal)).confidence, .likely)
    }

    /// A `@testable import` of the declaration's module opens its internal declarations to the file that has
    /// it, and to that file only: an import is file-scoped, so a name in another file of the target is some
    /// other declaration's.
    func testTestableImportMakesInternalDeclarationsVisibleToItsFile() {
        let graph = makeGraph()
        use(["Helper"])
        XCTAssertEqual(assessor(graph).assess(declaration("Helper", in: otherFile)).confidence, .certain)

        evidence.addUnscannedTargetNames(NameSites(names: ["Other": site], memberNames: [:], constructionNames: [:]), target: "WidgetsExtension", testableModules: ["App"])
        XCTAssertEqual(assessor(graph).assess(declaration("Helper", in: otherFile)).confidence, .certain, "Named only in a file without the import")
        XCTAssertEqual(assessor(graph).assess(declaration("Other", in: otherFile)).confidence, .likely)
        // Not a file-scoped one, which no import opens.
        evidence.addUnscannedTargetNames(NameSites(names: ["Secret": site], memberNames: [:], constructionNames: [:]), target: "WidgetsExtension", testableModules: ["App"])
        XCTAssertEqual(assessor(graph).assess(declaration("Secret", in: otherFile, accessibility: .private)).confidence, .certain)
    }

    func testSubscriptsAreMatchedThroughTheirType() {
        let graph = makeGraph()
        let type = declaration("Store", kind: .class, in: otherFile, accessibility: .public)
        let subscriptDeclaration = declaration("subscript(_:)", kind: .functionSubscript, in: otherFile, accessibility: .public, parent: type)
        use(["subscript"], members: ["subscript"], construction: ["subscript"])
        XCTAssertEqual(assessor(graph).assess(subscriptDeclaration).confidence, .certain)

        use(["Store"])
        XCTAssertEqual(assessor(graph).assess(subscriptDeclaration).confidence, .likely)
    }

    /// Naming a type says nothing about a member of it that nothing references; the type being used by the
    /// unscanned target is why the member is reported at all.
    func testNamingATypeDoesNotDowngradeItsUnreferencedMembers() {
        let graph = makeGraph()
        let type = declaration("Store", kind: .class, in: otherFile, accessibility: .public)
        let member = declaration("deleteAll()", kind: .functionMethodInstance, in: otherFile, accessibility: .public, parent: type)
        graph.add([type, member])
        use(["Store"])

        XCTAssertEqual(assessor(graph).assess(type).confidence, .likely)
        XCTAssertEqual(assessor(graph).assess(member).confidence, .certain)
    }

    /// `T.Item` names the associated type through a type, so the protocol must be named too.
    func testAssociatedTypesAreMatchedThroughTheirProtocol() {
        let graph = makeGraph()
        let protocolDeclaration = declaration("P", kind: .protocol, in: otherFile, accessibility: .public)
        let item = declaration("Item", kind: .associatedtype, in: otherFile, accessibility: .public, parent: protocolDeclaration)
        let other = declaration("Element", kind: .associatedtype, in: otherFile, accessibility: .public, parent: protocolDeclaration)
        use(["Item"], members: ["Item"])
        XCTAssertEqual(assessor(graph).assess(item).confidence, .certain)

        use(["P"])
        XCTAssertEqual(assessor(graph).assess(item).confidence, .likely)
        XCTAssertEqual(assessor(graph).assess(other).confidence, .certain, "The control: not named")
    }

    /// `typealias Store = AppStore` lets a file name `AppStore`'s members as `Store.shared`.
    func testTypeAliasesNameTheTypeForItsMembers() {
        let graph = makeGraph()
        let type = declaration("AppStore", kind: .class, in: otherFile, accessibility: .public)
        let member = declaration("shared", kind: .varStatic, in: otherFile, accessibility: .public, parent: type)
        let alias = declaration("Store", kind: .typealias, in: otherFile, accessibility: .public)
        let reference = Reference(name: "AppStore", kind: .normal, declarationKind: .class, usr: "s:class:AppStore", location: alias.location)
        alias.references.insert(reference)
        graph.add([type, member, alias])
        use(["Store", "shared"], members: ["shared"])

        XCTAssertEqual(assessor(graph).assess(member).confidence, .likely)
    }

    /// An extension is reported only with its unused type, so it is as sure as the type.
    func testExtensionsFollowTheirType() {
        let graph = makeGraph()
        let type = declaration("Widget", kind: .struct, in: otherFile, accessibility: .public)
        let ext = declaration("Widget", kind: .extensionStruct, in: otherFile, accessibility: .public)
        let reference = Reference(name: "Widget", kind: .normal, declarationKind: .struct, usr: "s:struct:Widget", location: ext.location)
        ext.references.insert(reference)
        graph.add([type, ext])
        use(["Widget"])

        let assessment = assessor(graph).assess(ext)
        XCTAssertEqual(assessment.confidence, .likely)
        XCTAssertEqual(assessment.reason, "it extends Widget, and its name appears in \(place)")
    }

    func testMacrosAreMatchedByName() {
        let graph = makeGraph()
        use(["makeWidget"])

        XCTAssertEqual(assessor(graph).assess(declaration("makeWidget()", kind: .macro, in: otherFile, accessibility: .public)).confidence, .likely)
    }

    func testMembersAndEnumCasesNeedTheirOwnTiers() {
        let graph = makeGraph()
        use(["field", "matched"], members: ["matched"])

        XCTAssertEqual(assessor(graph).assess(declaration("field", kind: .varInstance, accessibility: .public)).confidence, .certain)
        XCTAssertEqual(assessor(graph).assess(declaration("matched", kind: .varInstance, accessibility: .public)).confidence, .likely)
        // Matched in a pattern is not constructed.
        XCTAssertEqual(assessor(graph).assess(declaration("matched", kind: .enumelement, accessibility: .public, line: 2)).confidence, .certain)
    }

    func testSuppressedWhenNoTargetNamesIt() {
        let graph = makeGraph()
        use(["Other"])

        XCTAssertEqual(assessor(graph).assess(declaration("Widget")).confidence, .certain)
    }

    /// `SharedEntry` is named nowhere, and only an unused `SharedWidget`'s property refers to it.
    func testDeclarationReferencedOnlyFromALikelyDeclarationIsLikely() {
        let graph = makeGraph()
        use(["Widget"])
        let widget = declaration("Widget")
        let property = declaration("entry", kind: .varInstance, parent: widget)
        let entry = declaration("Entry")
        let reference = Reference(name: "Entry", kind: .normal, declarationKind: .struct, usr: "s:struct:Entry", location: property.location)
        reference.parent = property
        graph.add([widget, property, entry])
        graph.add(reference)

        let assessment = assessor(graph).assess(entry)
        XCTAssertEqual(assessment.confidence, .likely)
        XCTAssertEqual(assessment.reason, "it is used by Widget, whose name appears in \(place)")
        XCTAssertEqual(assessor(graph).assess(widget).reason, "its name appears in \(place)")
    }

    func testChainFollowsSeveralStepsAndSurvivesCycles() {
        let graph = makeGraph()
        use(["Widget"])
        let widget = declaration("Widget")
        let middle = declaration("Middle")
        let leaf = declaration("Leaf")
        // Widget -> Middle -> Leaf -> Middle.
        let links = [(widget, middle), (middle, leaf), (leaf, middle)]
        graph.add([widget, middle, leaf])
        for (from, to) in links {
            let reference = Reference(name: to.name, kind: .normal, declarationKind: .struct, usr: "s:struct:\(to.name)", location: from.location)
            reference.parent = from
            graph.add(reference)
        }

        XCTAssertEqual(assessor(graph).assess(leaf).reason, "it is used by Widget, whose name appears in \(place)")
        XCTAssertEqual(assessor(graph).assess(middle).confidence, .likely)
    }

    /// The parent's own reason may come from an earlier rule, as on a type whose name is also in a string
    /// literal; its unscanned-target match still passes the name on.
    func testChainFollowsAParentWhoseOwnReasonIsAnEarlierRule() {
        let graph = makeGraph()
        use(["Widget"])
        evidence.addClangLiteralTokens(["Widget"])
        let widget = declaration("Widget")
        let entry = declaration("Entry")
        let reference = Reference(name: "Entry", kind: .normal, declarationKind: .struct, usr: "s:struct:Entry", location: widget.location)
        reference.parent = widget
        graph.add([widget, entry])
        graph.add(reference)

        XCTAssertEqual(assessor(graph).assess(widget).reason, "its name appears in a string literal")
        XCTAssertEqual(assessor(graph).assess(entry).reason, "it is used by Widget, whose name appears in \(place)")
    }

    /// A declaration used by scanned code is not reported at all, so it passes nothing on to what it refers to.
    func testUsedDeclarationDoesNotPassTheNameOn() {
        let graph = makeGraph()
        use(["Widget"])
        let widget = declaration("Widget")
        let entry = declaration("Entry")
        let reference = Reference(name: "Entry", kind: .normal, declarationKind: .struct, usr: "s:struct:Entry", location: widget.location)
        reference.parent = widget
        graph.add([widget, entry])
        graph.add(reference)
        graph.markUsed(widget)

        XCTAssertEqual(assessor(graph).assess(entry).confidence, .certain)
    }

    func testAnswerFollowsLaterChangesToUsedDeclarations() {
        let graph = makeGraph()
        use(["Widget"])
        let widget = declaration("Widget")
        let entry = declaration("Entry")
        let reference = Reference(name: "Entry", kind: .normal, declarationKind: .struct, usr: "s:struct:Entry", location: widget.location)
        reference.parent = widget
        graph.add([widget, entry])
        graph.add(reference)

        XCTAssertEqual(assessor(graph).assess(entry).confidence, .likely)
        graph.markUsed(widget)
        XCTAssertEqual(assessor(graph).assess(entry).confidence, .certain)
    }

    func testSmallestSiteAcrossTargetsWins() {
        let graph = makeGraph()
        evidence.addUnscannedTargetNames(NameSites(names: ["Widget": "Z.swift:1"], memberNames: [:], constructionNames: [:]), target: "Zed", sharedSourceFiles: [sharedFile])
        evidence.addUnscannedTargetNames(NameSites(names: ["Widget": "A.swift:9"], memberNames: [:], constructionNames: [:]), target: "Alpha", sharedSourceFiles: [sharedFile])

        XCTAssertEqual(
            assessor(graph).assess(declaration("Widget")).reason,
            "its name appears in A.swift:9, a file of target Alpha, which the scanned schemes do not build"
        )
    }

    /// A target that does not compile the declaration's file cannot see an internal declaration, even when
    /// another target that does names it somewhere else.
    func testVisibilityIsPerTarget() {
        let graph = makeGraph()
        evidence.addUnscannedTargetNames(NameSites(names: ["Widget": "A.swift:9"], memberNames: [:], constructionNames: [:]), target: "Alpha", sharedSourceFiles: [otherFile])
        evidence.addUnscannedTargetNames(NameSites(names: [:], memberNames: [:], constructionNames: [:]), target: "Beta", sharedSourceFiles: [sharedFile])

        XCTAssertEqual(assessor(graph).assess(declaration("Widget")).confidence, .certain)
    }

    /// Other rules keep their place: a string literal comes first.
    func testStringLiteralReasonComesFirst() {
        let graph = makeGraph()
        use(["Widget"])
        evidence.addClangLiteralTokens(["Widget"])

        XCTAssertEqual(assessor(graph).assess(declaration("Widget")).reason, "its name appears in a string literal")
    }
}
