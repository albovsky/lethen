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

    private func use(_ graph: SourceGraph, _ names: [String], members: [String] = [], construction: [String] = []) {
        graph.addUnscannedTargetNames(
            names: Dictionary(uniqueKeysWithValues: names.map { ($0, site) }),
            members: Dictionary(uniqueKeysWithValues: members.map { ($0, site) }),
            construction: Dictionary(uniqueKeysWithValues: construction.map { ($0, site) }),
            target: "WidgetsExtension",
            sharedSourceFiles: [sharedFile]
        )
    }

    func testNameInAFileTheTargetCompilesIsLikely() {
        let graph = makeGraph()
        use(graph, ["Widget"])

        let assessment = graph.assessConfidence(of: declaration("Widget"))
        XCTAssertEqual(assessment.confidence, .likely)
        XCTAssertEqual(assessment.reason, "its name appears in \(place)")
    }

    func testInternalDeclarationOutsideTheTargetsFilesIsCertain() {
        let graph = makeGraph()
        use(graph, ["Widget"])

        XCTAssertEqual(graph.assessConfidence(of: declaration("Widget", in: otherFile)).confidence, .certain)
    }

    func testPublicDeclarationIsLikelyWhereverItIsDeclared() {
        let graph = makeGraph()
        use(graph, ["Widget"])

        XCTAssertEqual(graph.assessConfidence(of: declaration("Widget", in: otherFile, accessibility: .public)).confidence, .likely)
        XCTAssertEqual(graph.assessConfidence(of: declaration("Widget", in: otherFile, accessibility: .open)).confidence, .likely)
    }

    /// A public member of an internal type is not visible outside its module.
    func testPublicMemberOfAnInternalTypeIsNotVisible() {
        let graph = makeGraph()
        use(graph, ["run"], members: ["run"])
        let type = declaration("Hidden", kind: .class, in: otherFile)
        let member = declaration("run()", kind: .functionMethodInstance, in: otherFile, accessibility: .public, parent: type)

        XCTAssertEqual(graph.assessConfidence(of: member).confidence, .certain)
    }

    /// A member is reached through its type, so a target that uses `.shared` or `.init` on some other type
    /// does not use this one; naming the type as well is what makes the member reachable.
    func testMembersNeedTheirTypeNamedByTheSameTarget() {
        let graph = makeGraph()
        let type = declaration("Store", kind: .class, in: otherFile, accessibility: .public)
        let member = declaration("shared", kind: .varStatic, in: otherFile, accessibility: .public, parent: type)
        let initializer = declaration("init(url:)", kind: .functionConstructor, in: otherFile, accessibility: .public, parent: type)

        use(graph, ["shared", "init"], members: ["shared", "init"], construction: ["shared", "init"])
        XCTAssertEqual(graph.assessConfidence(of: member).confidence, .certain)
        XCTAssertEqual(graph.assessConfidence(of: initializer).confidence, .certain)

        use(graph, ["Store"])
        XCTAssertEqual(graph.assessConfidence(of: member).confidence, .likely)
        XCTAssertEqual(graph.assessConfidence(of: initializer).confidence, .likely)
    }

    /// A member of a type in a file the target compiles is reached through the type there too.
    func testMembersOfASharedFileNeedTheirTypeNamedAsWell() {
        let graph = makeGraph()
        let type = declaration("Widget", kind: .struct)
        let member = declaration("entry", kind: .varInstance, parent: type)
        use(graph, ["entry"], members: ["entry"])
        XCTAssertEqual(graph.assessConfidence(of: member).confidence, .certain)

        use(graph, ["Widget"])
        XCTAssertEqual(graph.assessConfidence(of: member).confidence, .likely)
    }

    /// The shared file is not read, so a matching name is in another file, which cannot reach a private or
    /// fileprivate declaration.
    func testFileScopedDeclarationsInASharedFileStayCertain() {
        let graph = makeGraph()
        use(graph, ["Widget", "Helper"])

        XCTAssertEqual(graph.assessConfidence(of: declaration("Widget", accessibility: .private)).confidence, .certain)
        XCTAssertEqual(graph.assessConfidence(of: declaration("Widget", accessibility: .fileprivate)).confidence, .certain)
        XCTAssertEqual(graph.assessConfidence(of: declaration("Helper", accessibility: .internal)).confidence, .likely)
    }

    /// A `@testable import` of the declaration's module opens its internal declarations to the file that has
    /// it, and to that file only: an import is file-scoped, so a name in another file of the target is some
    /// other declaration's.
    func testTestableImportMakesInternalDeclarationsVisibleToItsFile() {
        let graph = makeGraph()
        use(graph, ["Helper"])
        XCTAssertEqual(graph.assessConfidence(of: declaration("Helper", in: otherFile)).confidence, .certain)

        graph.addUnscannedTargetNames(names: ["Other": site], members: [:], construction: [:], target: "WidgetsExtension", testableModules: ["App"])
        XCTAssertEqual(graph.assessConfidence(of: declaration("Helper", in: otherFile)).confidence, .certain, "Named only in a file without the import")
        XCTAssertEqual(graph.assessConfidence(of: declaration("Other", in: otherFile)).confidence, .likely)
        // Not a file-scoped one, which no import opens.
        graph.addUnscannedTargetNames(names: ["Secret": site], members: [:], construction: [:], target: "WidgetsExtension", testableModules: ["App"])
        XCTAssertEqual(graph.assessConfidence(of: declaration("Secret", in: otherFile, accessibility: .private)).confidence, .certain)
    }

    func testSubscriptsAreMatchedThroughTheirType() {
        let graph = makeGraph()
        let type = declaration("Store", kind: .class, in: otherFile, accessibility: .public)
        let subscriptDeclaration = declaration("subscript(_:)", kind: .functionSubscript, in: otherFile, accessibility: .public, parent: type)
        use(graph, ["subscript"], members: ["subscript"], construction: ["subscript"])
        XCTAssertEqual(graph.assessConfidence(of: subscriptDeclaration).confidence, .certain)

        use(graph, ["Store"])
        XCTAssertEqual(graph.assessConfidence(of: subscriptDeclaration).confidence, .likely)
    }

    /// Naming a type says nothing about a member of it that nothing references; the type being used by the
    /// unscanned target is why the member is reported at all.
    func testNamingATypeDoesNotDowngradeItsUnreferencedMembers() {
        let graph = makeGraph()
        let type = declaration("Store", kind: .class, in: otherFile, accessibility: .public)
        let member = declaration("deleteAll()", kind: .functionMethodInstance, in: otherFile, accessibility: .public, parent: type)
        graph.add([type, member])
        use(graph, ["Store"])

        XCTAssertEqual(graph.assessConfidence(of: type).confidence, .likely)
        XCTAssertEqual(graph.assessConfidence(of: member).confidence, .certain)
    }

    /// `T.Item` names the associated type through a type, so the protocol must be named too.
    func testAssociatedTypesAreMatchedThroughTheirProtocol() {
        let graph = makeGraph()
        let protocolDeclaration = declaration("P", kind: .protocol, in: otherFile, accessibility: .public)
        let item = declaration("Item", kind: .associatedtype, in: otherFile, accessibility: .public, parent: protocolDeclaration)
        let other = declaration("Element", kind: .associatedtype, in: otherFile, accessibility: .public, parent: protocolDeclaration)
        use(graph, ["Item"], members: ["Item"])
        XCTAssertEqual(graph.assessConfidence(of: item).confidence, .certain)

        use(graph, ["P"])
        XCTAssertEqual(graph.assessConfidence(of: item).confidence, .likely)
        XCTAssertEqual(graph.assessConfidence(of: other).confidence, .certain, "The control: not named")
    }

    func testMacrosAreMatchedByName() {
        let graph = makeGraph()
        use(graph, ["makeWidget"])

        XCTAssertEqual(graph.assessConfidence(of: declaration("makeWidget()", kind: .macro, in: otherFile, accessibility: .public)).confidence, .likely)
    }

    func testMembersAndEnumCasesNeedTheirOwnTiers() {
        let graph = makeGraph()
        use(graph, ["field", "matched"], members: ["matched"])

        XCTAssertEqual(graph.assessConfidence(of: declaration("field", kind: .varInstance, accessibility: .public)).confidence, .certain)
        XCTAssertEqual(graph.assessConfidence(of: declaration("matched", kind: .varInstance, accessibility: .public)).confidence, .likely)
        // Matched in a pattern is not constructed.
        XCTAssertEqual(graph.assessConfidence(of: declaration("matched", kind: .enumelement, accessibility: .public, line: 2)).confidence, .certain)
    }

    func testSuppressedWhenNoTargetNamesIt() {
        let graph = makeGraph()
        use(graph, ["Other"])

        XCTAssertEqual(graph.assessConfidence(of: declaration("Widget")).confidence, .certain)
    }

    /// `SharedEntry` is named nowhere, and only an unused `SharedWidget`'s property refers to it.
    func testDeclarationReferencedOnlyFromALikelyDeclarationIsLikely() {
        let graph = makeGraph()
        use(graph, ["Widget"])
        let widget = declaration("Widget")
        let property = declaration("entry", kind: .varInstance, parent: widget)
        let entry = declaration("Entry")
        let reference = Reference(name: "Entry", kind: .normal, declarationKind: .struct, usr: "s:struct:Entry", location: property.location)
        reference.parent = property
        graph.add([widget, property, entry])
        graph.add(reference)

        let assessment = graph.assessConfidence(of: entry)
        XCTAssertEqual(assessment.confidence, .likely)
        XCTAssertEqual(assessment.reason, "it is used by Widget, whose name appears in \(place)")
        XCTAssertEqual(graph.assessConfidence(of: widget).reason, "its name appears in \(place)")
    }

    func testChainFollowsSeveralStepsAndSurvivesCycles() {
        let graph = makeGraph()
        use(graph, ["Widget"])
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

        XCTAssertEqual(graph.assessConfidence(of: leaf).reason, "it is used by Widget, whose name appears in \(place)")
        XCTAssertEqual(graph.assessConfidence(of: middle).confidence, .likely)
    }

    /// The parent's own reason may come from an earlier rule, as on a type whose name is also in a string
    /// literal; its unscanned-target match still passes the name on.
    func testChainFollowsAParentWhoseOwnReasonIsAnEarlierRule() {
        let graph = makeGraph()
        use(graph, ["Widget"])
        graph.addLiteralTokens(["Widget"])
        let widget = declaration("Widget")
        let entry = declaration("Entry")
        let reference = Reference(name: "Entry", kind: .normal, declarationKind: .struct, usr: "s:struct:Entry", location: widget.location)
        reference.parent = widget
        graph.add([widget, entry])
        graph.add(reference)

        XCTAssertEqual(graph.assessConfidence(of: widget).reason, "its name appears in a string literal")
        XCTAssertEqual(graph.assessConfidence(of: entry).reason, "it is used by Widget, whose name appears in \(place)")
    }

    /// A declaration used by scanned code is not reported at all, so it passes nothing on to what it refers to.
    func testUsedDeclarationDoesNotPassTheNameOn() {
        let graph = makeGraph()
        use(graph, ["Widget"])
        let widget = declaration("Widget")
        let entry = declaration("Entry")
        let reference = Reference(name: "Entry", kind: .normal, declarationKind: .struct, usr: "s:struct:Entry", location: widget.location)
        reference.parent = widget
        graph.add([widget, entry])
        graph.add(reference)
        graph.markUsed(widget)

        XCTAssertEqual(graph.assessConfidence(of: entry).confidence, .certain)
    }

    func testAnswerFollowsLaterChangesToUsedDeclarations() {
        let graph = makeGraph()
        use(graph, ["Widget"])
        let widget = declaration("Widget")
        let entry = declaration("Entry")
        let reference = Reference(name: "Entry", kind: .normal, declarationKind: .struct, usr: "s:struct:Entry", location: widget.location)
        reference.parent = widget
        graph.add([widget, entry])
        graph.add(reference)

        XCTAssertEqual(graph.assessConfidence(of: entry).confidence, .likely)
        graph.markUsed(widget)
        XCTAssertEqual(graph.assessConfidence(of: entry).confidence, .certain)
    }

    func testSmallestSiteAcrossTargetsWins() {
        let graph = makeGraph()
        graph.addUnscannedTargetNames(names: ["Widget": "Z.swift:1"], members: [:], construction: [:], target: "Zed", sharedSourceFiles: [sharedFile])
        graph.addUnscannedTargetNames(names: ["Widget": "A.swift:9"], members: [:], construction: [:], target: "Alpha", sharedSourceFiles: [sharedFile])

        XCTAssertEqual(
            graph.assessConfidence(of: declaration("Widget")).reason,
            "its name appears in A.swift:9, a file of target Alpha, which the scanned schemes do not build"
        )
    }

    /// A target that does not compile the declaration's file cannot see an internal declaration, even when
    /// another target that does names it somewhere else.
    func testVisibilityIsPerTarget() {
        let graph = makeGraph()
        graph.addUnscannedTargetNames(names: ["Widget": "A.swift:9"], members: [:], construction: [:], target: "Alpha", sharedSourceFiles: [otherFile])
        graph.addUnscannedTargetNames(names: [:], members: [:], construction: [:], target: "Beta", sharedSourceFiles: [sharedFile])

        XCTAssertEqual(graph.assessConfidence(of: declaration("Widget")).confidence, .certain)
    }

    /// Other rules keep their place: a string literal comes first.
    func testStringLiteralReasonComesFirst() {
        let graph = makeGraph()
        use(graph, ["Widget"])
        graph.addLiteralTokens(["Widget"])

        XCTAssertEqual(graph.assessConfidence(of: declaration("Widget")).reason, "its name appears in a string literal")
    }
}
