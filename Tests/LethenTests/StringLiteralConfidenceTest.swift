import Configuration
import Logger
@testable import SourceGraph
import SystemPackage
import XCTest

final class StringLiteralConfidenceTest: XCTestCase {
    private func assess(
        name: String,
        kind: Declaration.Kind = .functionMethodInstance,
        usrs: Set<String> = ["s:swiftOnly"],
        attributes: [String] = [],
        evidence configure: (inout ConfidenceEvidence) -> Void
    ) -> ConfidenceAssessment {
        let graph = SourceGraph(configuration: Configuration(), logger: Logger(quiet: true, verbose: false, colorMode: .never))
        var evidence = ConfidenceEvidence()
        // Every Objective-C file was read, so the Objective-C coverage rule stays out of the way.
        evidence.clangCoverage = ClangCoverage(unindexedFiles: [])
        configure(&evidence)
        let file = SourceFile(path: FilePath("/p/A.swift"), modules: ["A"])
        let declaration = Declaration(name: name, kind: kind, usrs: usrs, location: Location(file: file, line: 1, column: 1))
        declaration.attributes = Set(attributes.map { DeclarationAttribute(name: $0, arguments: nil) })
        return ConfidenceAssessor(evidence: evidence, graph: graph, configuration: Configuration()).assess(declaration)
    }

    func testObjcMethodNamedByABareLiteralIsLikely() {
        let assessment = assess(name: "handleTap()", attributes: ["objc"]) { $0.addLiteralTokens(["handleTap"]) }
        XCTAssertEqual(assessment, ConfidenceAssessment(confidence: .likely, reason: "its name appears in a string literal"))
    }

    func testMembersTheObjcRuntimeReachesAreMatchedByABareLiteral() {
        // An Objective-C USR is how the index marks a member an `NSObject` subclass exposes without `@objc`.
        let inherited = assess(name: "refresh()", usrs: ["c:@M@A@objc(cs)Controller(im)refresh"]) { $0.addLiteralTokens(["refresh"]) }
        XCTAssertEqual(inherited.confidence, .likely)
        let managed = assess(name: "title", kind: .varInstance, attributes: ["NSManaged"]) { $0.addLiteralTokens(["title"]) }
        XCTAssertEqual(managed.confidence, .likely)
    }

    func testPureSwiftFunctionNamedByABareLiteralIsCertain() {
        XCTAssertEqual(assess(name: "username()") { $0.addLiteralTokens(["username"]) }.confidence, .certain)
        XCTAssertEqual(assess(name: "username", kind: .varInstance) { $0.addLiteralTokens(["username"]) }.confidence, .certain)
    }

    func testPureSwiftClassPassedToNSClassFromStringIsLikely() {
        let assessment = assess(name: "Foo", kind: .class) { $0.addReflectionSites(["Foo": "NSClassFromString at Loader.swift:4"]) }
        XCTAssertEqual(assessment, ConfidenceAssessment(
            confidence: .likely,
            reason: "its name appears in a string passed to NSClassFromString at Loader.swift:4"
        ))
    }

    func testPropertyComparedAgainstAMirrorLabelIsLikely() {
        let assessment = assess(name: "secret", kind: .varInstance) { $0.addReflectionSites(["secret": "a Mirror label comparison at Dump.swift:9"]) }
        XCTAssertEqual(assessment.confidence, .likely)
        XCTAssertEqual(assessment.reason, "its name appears in a string passed to a Mirror label comparison at Dump.swift:9")
    }

    func testObjectiveCFileLiteralNamesAPureSwiftClassButNothingElse() {
        // `NSClassFromString` loads any Swift class by its runtime name, so the literal may name it.
        XCTAssertEqual(assess(name: "Foo", kind: .class) { $0.addClangLiteralTokens(["Foo"]) }.confidence, .likely)
        // No selector, key or key path resolves to a pure-Swift member, function, struct, enum or protocol.
        XCTAssertEqual(assess(name: "title", kind: .varInstance) { $0.addClangLiteralTokens(["title"]) }.confidence, .certain)
        XCTAssertEqual(assess(name: "load()") { $0.addClangLiteralTokens(["load"]) }.confidence, .certain)
        XCTAssertEqual(assess(name: "Foo", kind: .struct) { $0.addClangLiteralTokens(["Foo"]) }.confidence, .certain)
        XCTAssertEqual(assess(name: "Foo", kind: .enum) { $0.addClangLiteralTokens(["Foo"]) }.confidence, .certain)
        XCTAssertEqual(assess(name: "Foo", kind: .protocol) { $0.addClangLiteralTokens(["Foo"]) }.confidence, .certain)
        XCTAssertEqual(assess(name: "ready", kind: .enumelement) { $0.addClangLiteralTokens(["ready"]) }.confidence, .certain)
        XCTAssertEqual(assess(name: "load()") { $0.addClangLiteralSelectors(["load:"]) }.confidence, .certain)
    }

    func testObjectiveCFileLiteralNamesAFunctionExportedAsACSymbol() {
        func exported(_ attribute: String, _ symbol: String) -> ConfidenceAssessment {
            let file = SourceFile(path: FilePath("/p/A.swift"), modules: ["A"])
            let graph = SourceGraph(configuration: Configuration(), logger: Logger(quiet: true, verbose: false, colorMode: .never))
            var evidence = ConfidenceEvidence()
            evidence.clangCoverage = ClangCoverage(unindexedFiles: [])
            evidence.addClangLiteralTokens([symbol])
            let declaration = Declaration(name: "entry()", kind: .functionFree, usrs: ["s:entry"], location: Location(file: file, line: 1, column: 1))
            declaration.attributes = [DeclarationAttribute(name: attribute, arguments: "(\"plugin_entry\")")]
            return ConfidenceAssessor(evidence: evidence, graph: graph, configuration: Configuration()).assess(declaration)
        }
        XCTAssertEqual(exported("_cdecl", "plugin_entry").confidence, .likely)
        XCTAssertEqual(exported("_silgen_name", "plugin_entry").confidence, .likely)
        // Control: the literal must spell the exported symbol, not the Swift name, and the attribute must be a C export.
        XCTAssertEqual(exported("_cdecl", "entry").confidence, .certain)
        XCTAssertEqual(exported("inline", "plugin_entry").confidence, .certain)
    }

    func testObjectiveCFileLiteralStillNamesWhatTheObjectiveCRuntimeReaches() {
        XCTAssertEqual(assess(name: "title", kind: .varInstance, attributes: ["objc"]) { $0.addClangLiteralTokens(["title"]) }.confidence, .likely)
        XCTAssertEqual(assess(name: "handleTap()", attributes: ["objc"]) { $0.addClangLiteralTokens(["handleTap"]) }.confidence, .likely)
        let managed = assess(name: "title", kind: .varInstance, attributes: ["NSManaged"]) { $0.addClangLiteralTokens(["title"]) }
        XCTAssertEqual(managed.confidence, .likely)
    }

    func testSelectorLiteralNamesTheMethodWhoseWholeSelectorItSpells() {
        let usrs: Set<String> = ["s:swiftLoad", "c:@M@App@objc(cs)Store(im)load:from:"]
        func method(_ selectors: Set<String>) -> ConfidenceAssessment {
            assess(name: "load(_:from:)", usrs: usrs, attributes: ["objc"]) { $0.addClangLiteralSelectors(selectors) }
        }
        XCTAssertEqual(method(["load:from:"]), ConfidenceAssessment(confidence: .likely, reason: "its name appears in a string literal"))
        XCTAssertEqual(method(["load:"]).confidence, .certain)
        XCTAssertEqual(method(["setTitle:forState:"]).confidence, .certain)
        // The same holds for a selector a Swift literal spells.
        let swiftLiteral = assess(name: "load(_:from:)", usrs: usrs, attributes: ["objc"]) { $0.addLiteralSelectors(["load:from:"]) }
        XCTAssertEqual(swiftLiteral.confidence, .likely)
        let swiftPiece = assess(name: "load(_:from:)", usrs: usrs, attributes: ["objc"]) { $0.addLiteralSelectors(["load:"]) }
        XCTAssertEqual(swiftPiece.confidence, .certain)
    }

    func testSelectorLiteralNamesAnObjcPropertyByItsGetterOrSetterOnly() {
        func property(_ configure: @escaping (inout ConfidenceEvidence) -> Void) -> ConfidenceAssessment {
            assess(name: "title", kind: .varInstance, attributes: ["objc"], evidence: configure)
        }
        XCTAssertEqual(property { $0.addClangLiteralSelectors(["setTitle:"]) }.confidence, .likely)
        XCTAssertEqual(property { $0.addClangLiteralSelectors(["title"]) }.confidence, .likely)
        XCTAssertEqual(property { $0.addClangLiteralTokens(["title"]) }.confidence, .likely)
        XCTAssertEqual(property { $0.addClangLiteralSelectors(["setTitle:forState:"]) }.confidence, .certain)
        XCTAssertEqual(property { $0.addClangLiteralSelectors(["title:"]) }.confidence, .certain)
    }

    func testPropertySelectorsComeFromItsObjcUSRWhenItHasOne() {
        let indexed: Set<String> = ["s:swiftTitle", "c:@M@A@objc(cs)Store(py)title"]
        func property(_ configure: @escaping (inout ConfidenceEvidence) -> Void) -> ConfidenceAssessment {
            assess(name: "title", kind: .varInstance, usrs: indexed, attributes: ["objc"], evidence: configure)
        }
        XCTAssertEqual(property { $0.addClangLiteralSelectors(["setTitle:"]) }.confidence, .likely)
        XCTAssertEqual(property { $0.addClangLiteralSelectors(["title"]) }.confidence, .likely)
        // The colonless `setTitle` is a name the lookup tokens hold, never the setter's selector.
        XCTAssertEqual(property { $0.addClangLiteralSelectors(["setTitle"]) }.confidence, .certain)
        // `@objc(displayTitle)` renames the getter, so the Swift name no longer spells a selector of it.
        let renamed: Set<String> = ["s:swiftTitle", "c:@M@A@objc(cs)Store(py)displayTitle"]
        func renamedProperty(_ selectors: Set<String>) -> ConfidenceAssessment {
            assess(name: "title", kind: .varInstance, usrs: renamed, attributes: ["objc"]) { $0.addClangLiteralSelectors(selectors) }
        }
        XCTAssertEqual(renamedProperty(["title"]).confidence, .certain)
        XCTAssertEqual(renamedProperty(["setTitle:"]).confidence, .certain)
        XCTAssertEqual(renamedProperty(["displayTitle"]).confidence, .likely)
        XCTAssertEqual(renamedProperty(["setDisplayTitle:"]).confidence, .likely)
    }

    func testSelectorPassedToAReflectionAPINamesOnlyTheMethodWhoseSelectorItSpells() {
        let usrs: Set<String> = ["s:swiftLoad", "c:@M@App@objc(cs)Store(im)load:from:"]
        func method(_ selector: String) -> ConfidenceAssessment {
            assess(name: "load(_:from:)", usrs: usrs, attributes: ["objc"]) {
                $0.addReflectionSelectorSites([selector: "NSSelectorFromString at Loader.swift:4"])
            }
        }
        XCTAssertEqual(method("load:from:"), ConfidenceAssessment(
            confidence: .likely,
            reason: "its name appears in a string passed to NSSelectorFromString at Loader.swift:4"
        ))
        XCTAssertEqual(method("load:").confidence, .certain)
    }

    func testNSManagedPropertyKeepsMatchingItsKey() {
        let managed = assess(name: "title", kind: .varInstance, attributes: ["NSManaged"]) { $0.addClangLiteralTokens(["title"]) }
        XCTAssertEqual(managed.confidence, .likely)
        let selector = assess(name: "title", kind: .varInstance, attributes: ["NSManaged"]) { $0.addClangLiteralSelectors(["setTitle:"]) }
        XCTAssertEqual(selector.confidence, .likely)
    }

    func testObjcMethodWithoutAClangUSRIsStillNamedByItsFirstSelectorPart() {
        // Without a selector to compare with, the first part stands for it, which errs towards `likely`.
        let named = assess(name: "load(_:from:)", attributes: ["objc"]) { $0.addClangLiteralSelectors(["load:from:"]) }
        XCTAssertEqual(named.confidence, .likely)
        XCTAssertEqual(assess(name: "load(_:from:)", attributes: ["objc"]) { $0.addClangLiteralSelectors(["other:"]) }.confidence, .certain)
    }

    func testUnrelatedLiteralsAndSitesLeaveAnyDeclarationCertain() {
        let assessment = assess(name: "Foo", kind: .class, attributes: ["objc"]) {
            $0.addLiteralTokens(["Bar"])
            $0.addReflectionSites(["Baz": "NSClassFromString at Loader.swift:1"])
            $0.addClangLiteralTokens(["Qux"])
        }
        XCTAssertEqual(assessment.confidence, .certain)
    }
}
