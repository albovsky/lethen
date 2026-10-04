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

    func testObjectiveCFileLiteralKeepsNamingEveryDeclaration() {
        // The call that receives an Objective-C file's literal is not read, so it may be `NSClassFromString`.
        XCTAssertEqual(assess(name: "Foo", kind: .class) { $0.addClangLiteralTokens(["Foo"]) }.confidence, .likely)
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
