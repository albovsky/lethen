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
        literalTokens: Set<String> = [],
        usrs: Set<String> = ["s:exposed"],
        kind: Declaration.Kind = .functionMethodInstance,
        name: String = "exposed()"
    ) -> ConfidenceAssessment {
        let graph = SourceGraph(configuration: configuration, logger: Logger(quiet: true, verbose: false, colorMode: .never))
        var evidence = ConfidenceEvidence()
        evidence.clangCoverage = coverage
        evidence.addLiteralTokens(literalTokens)
        let file = SourceFile(path: FilePath("/p/A.swift"), modules: ["A"])
        let declaration = Declaration(name: name, kind: kind, usrs: usrs, location: Location(file: file, line: 1, column: 1))
        declaration.isObjcAccessible = isObjcAccessible
        return ConfidenceAssessor(evidence: evidence, graph: graph, configuration: configuration).assess(declaration)
    }

    func testEmptyEvidenceIsCertainWithoutWalkingReferences() {
        let graph = SourceGraph(configuration: Configuration(), logger: Logger(quiet: true, verbose: false, colorMode: .never))
        let assessor = ConfidenceAssessor(evidence: ConfidenceEvidence(), graph: graph, configuration: Configuration())
        let file = SourceFile(path: FilePath("/p/A.swift"), modules: ["A"])
        let declaration = Declaration(name: "plain()", kind: .functionMethodInstance, usrs: ["s:plain"], location: Location(file: file, line: 1, column: 1))
        XCTAssertEqual(assessor.assess(declaration), ConfidenceAssessment(confidence: .certain, reason: nil))
    }

    func testUnknownCoverageIsLikely() {
        let assessment = assess(coverage: nil)
        XCTAssertEqual(assessment.confidence, .likely)
        XCTAssertTrue(assessment.reason?.contains("cannot tell whether every Objective-C file") == true, assessment.reason ?? "")
    }

    func testOneUnindexedFileIsNamedInTheSingular() {
        let assessment = assess(coverage: files(["Foo.m"]))
        XCTAssertEqual(assessment.confidence, .likely)
        XCTAssertEqual(assessment.reason, "it is accessible from Objective-C, and 1 Objective-C file has no index unit (Foo.m), so a reference made from it would be missed")
    }

    func testSeveralUnindexedFilesListThreeNamesAndCountTheRest() {
        let assessment = assess(coverage: files(["A.m", "B.m", "C.m", "D.m", "E.m"]))
        XCTAssertEqual(assessment.confidence, .likely)
        XCTAssertEqual(assessment.reason, "it is accessible from Objective-C, and 5 Objective-C files have no index unit (A.m, B.m, C.m, and 2 more), so a reference made from them would be missed")
    }

    func testThreeUnindexedFilesListAllOfThem() {
        XCTAssertEqual(
            assess(coverage: files(["A.m", "B.m", "C.m"])).reason,
            "it is accessible from Objective-C, and 3 Objective-C files have no index unit (A.m, B.m, C.m), so a reference made from them would be missed"
        )
    }

    /// A file compiled into the index but unreadable at scan time may spell a lookup the scan cannot see.
    func testUnreadFileKeepsTheDeclarationLikelyAndIsNamedAfterUnindexedOnes() {
        let unread = assess(coverage: ClangCoverage(unindexedFiles: [], unreadFiles: [FilePath("/p/Gone.m")]))
        XCTAssertEqual(unread.confidence, .likely)
        XCTAssertEqual(unread.reason, "it is accessible from Objective-C, and 1 Objective-C file could not be read for string literals (Gone.m), so a reference made from it would be missed")

        let both = assess(coverage: ClangCoverage(unindexedFiles: [FilePath("/p/A.m")], unreadFiles: [FilePath("/p/Gone.m")]))
        XCTAssertEqual(both.reason, "it is accessible from Objective-C, and 1 Objective-C file has no index unit (A.m), so a reference made from it would be missed")
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

    /// `@objc(renamed)` gives the declaration a second name a runtime lookup can spell.
    func testCompleteCoverageStillDowngradesTheObjectiveCNameInAStringLiteral() {
        let usrs: Set<String> = ["s:exposed", "c:@M@App@objc(cs)Store(im)renamedForObjC:with:"]
        let renamed = assess(coverage: files([]), literalTokens: ["renamedForObjC"], usrs: usrs)
        XCTAssertEqual(renamed.confidence, .likely)
        XCTAssertEqual(renamed.reason, "its name appears in a string literal")

        // The control: the same declaration with no literal naming it either way.
        XCTAssertEqual(assess(coverage: files([]), literalTokens: ["other"], usrs: usrs).confidence, .certain)
    }

    /// An initializer is reached by its Objective-C selector, never by the word `init`.
    func testInitializerMatchesItsObjectiveCNameOnly() {
        let usrs: Set<String> = ["s:init", "c:@M@App@objc(cs)Store(im)initWithFoo:"]
        XCTAssertEqual(assess(coverage: files([]), literalTokens: ["initWithFoo"], usrs: usrs, kind: .functionConstructor, name: "init(foo:)").confidence, .likely)
        // The controls: `init` is not a lookup, and an unrelated token is not a match.
        XCTAssertEqual(assess(coverage: files([]), literalTokens: ["init"], usrs: usrs, kind: .functionConstructor, name: "init(foo:)").confidence, .certain)
        XCTAssertEqual(assess(coverage: files([]), literalTokens: ["other"], usrs: usrs, kind: .functionConstructor, name: "init(foo:)").confidence, .certain)
    }

    /// A property is written through its setter selector, `setFoo:`.
    func testPropertyMatchesItsSetterSelector() {
        let property: Set<String> = ["s:foo", "c:@M@App@objc(cs)Store(py)foo"]
        XCTAssertEqual(assess(coverage: files([]), literalTokens: ["setFoo"], usrs: property, kind: .varInstance, name: "foo").confidence, .likely)
        XCTAssertEqual(assess(coverage: files([]), literalTokens: ["foo"], usrs: property, kind: .varInstance, name: "foo").confidence, .likely)
        // The controls: a method has no setter, and an unrelated token is not a match.
        let method: Set<String> = ["s:foo", "c:@M@App@objc(cs)Store(im)foo"]
        XCTAssertEqual(assess(coverage: files([]), literalTokens: ["setFoo"], usrs: method).confidence, .certain)
        XCTAssertEqual(assess(coverage: files([]), literalTokens: ["setBar"], usrs: property, kind: .varInstance, name: "foo").confidence, .certain)
    }

    func testObjectiveCNameOfAUSR() {
        XCTAssertEqual(ConfidenceAssessor.objcName(fromUSR: "c:objc(cs)Store(im)load:from:"), "load")
        XCTAssertEqual(ConfidenceAssessor.objcName(fromUSR: "c:@M@App@objc(cs)Store(im)renamedForObjC"), "renamedForObjC")
        XCTAssertEqual(ConfidenceAssessor.objcName(fromUSR: "c:@M@App@objc(cs)RenamedClassForObjC"), "RenamedClassForObjC")
        XCTAssertEqual(ConfidenceAssessor.objcName(fromUSR: "c:@CM@App@@objc(cs)NSObject(py)wmf_value"), "wmf_value")
        XCTAssertNil(ConfidenceAssessor.objcName(fromUSR: "s:3App5StoreC4loadyyF"))
        XCTAssertNil(ConfidenceAssessor.objcName(fromUSR: "c:@M@App@objc(cs)"))
    }

    func testObjcSelectorFromUSRIsTheWholeSelectorOfAMethodOrProperty() {
        XCTAssertEqual(ConfidenceAssessor.objcSelector(fromUSR: "c:objc(cs)Store(im)load:from:"), "load:from:")
        XCTAssertEqual(ConfidenceAssessor.objcSelector(fromUSR: "c:@M@App@objc(cs)Store(cm)shared"), "shared")
        XCTAssertEqual(ConfidenceAssessor.objcSelector(fromUSR: "c:@CM@App@@objc(cs)NSObject(py)wmf_value"), "wmf_value")
        XCTAssertEqual(ConfidenceAssessor.objcSelector(fromUSR: "c:objc(cs)Store(im)initWithFoo:"), "initWithFoo:")
        XCTAssertNil(ConfidenceAssessor.objcSelector(fromUSR: "c:@M@App@objc(cs)RenamedClassForObjC"))
        XCTAssertNil(ConfidenceAssessor.objcSelector(fromUSR: "c:objc(pl)Delegate"))
        XCTAssertNil(ConfidenceAssessor.objcSelector(fromUSR: "s:3App5StoreC4loadyyF"))
        XCTAssertNil(ConfidenceAssessor.objcSelector(fromUSR: "c:@M@App@objc(cs)"))
        XCTAssertNil(ConfidenceAssessor.objcSelector(fromUSR: "c:objc(cs)Store(im)"))
    }
}
